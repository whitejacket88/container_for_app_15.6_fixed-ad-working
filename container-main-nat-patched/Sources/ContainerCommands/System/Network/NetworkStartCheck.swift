//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

public enum StartCheckResult: Equatable, Sendable {
    /// Carry on starting the container.
    case proceed
    /// Services were restarted, which stopped this container: bootstrap it again. When
    /// `pending` is set, pass it to `verifyAfterRebootstrap` once the container is up.
    case restartedNeedsRebootstrap(PendingVerification?)
}

/// The macOS 15 network check run by `container start` and `container run`.
///
/// It runs after the container is bootstrapped, because the host bridge for the shared
/// VM network only exists once a VM has attached to it.
public enum NetworkStartCheck {
    static let restartCommand = "container system stop && container system start"

    public static func run(
        containerId: String,
        client: ContainerClient,
        config: ContainerSystemConfig,
        console: Terminal?,
        log: Logger,
        io: PromptIO = .standard,
        control: any ContainerSystemControl = CLISystemControl()
    ) async -> StartCheckResult {
        guard config.network.shouldCheckOnStart,
            let snapshot = try? await client.get(id: containerId),
            let attachment = snapshot.networks.first,
            attachment.variant == "allocationOnly"
        else {
            return .proceed
        }

        let running = ((try? await client.list(filters: ContainerListFilters(status: .running))) ?? [])
            .map { RunningContainerInfo(id: $0.id, interactive: $0.configuration.initProcess.terminal) }
        let configFile = ConfigurationLoader.configurationFile(.home)
        let history = NetworkRepairHistory(file: historyFile())

        // The user's terminal may already be in raw mode for an interactive session.
        try? console?.reset()
        defer { try? console?.setraw() }

        let result = await evaluate(
            containerId: containerId,
            attachment: attachment,
            checkOnStart: true,
            running: running,
            userConfigText: (try? String(contentsOfFile: configFile.string, encoding: .utf8)) ?? "",
            repairer: NetworkRepairer(control: control, configFile: configFile, history: history),
            history: history,
            interfaces: control.hostInterfaces(),
            io: io,
            now: Date())
        log.info("network start check", metadata: ["id": "\(containerId)", "result": "\(result)"])
        return result
    }

    /// Confirms a repair once the container is running again; rolls back if it failed.
    ///
    /// - Returns: true if the repair worked. False means it was undone and services were
    ///   restarted again, so the caller must bootstrap the container once more.
    public static func verifyAfterRebootstrap(
        _ pending: PendingVerification,
        containerId: String,
        io: PromptIO = .standard,
        control: any ContainerSystemControl = CLISystemControl()
    ) async -> Bool {
        let configFile = ConfigurationLoader.configurationFile(.home)
        let repairer = NetworkRepairer(
            control: control, configFile: configFile, history: NetworkRepairHistory(file: historyFile()))
        if await repairer.verify(pending, id: containerId) {
            io.write("✔ Network repaired: container now uses \(NetworkRepairPrompt.range(pending.to)).\n")
            return true
        }
        io.write(
            "⚠ The repair didn't fix the network, so it was undone.\n"
                + "Run 'container system network check --admin' to find the right network.\n")
        return false
    }

    static func historyFile() -> FilePath {
        PathUtils.BaseConfigPath.appRoot.basePath().appending("network-repair.json")
    }

    static func evaluate(
        containerId: String,
        attachment: Attachment?,
        checkOnStart: Bool,
        running: [RunningContainerInfo],
        userConfigText: String,
        repairer: NetworkRepairer,
        history: NetworkRepairHistory,
        interfaces: [HostInterface],
        io: PromptIO,
        now: Date,
        systemSharedAddress: IPv4Address? = nil
    ) async -> StartCheckResult {
        guard checkOnStart, let attachment, attachment.variant == "allocationOnly",
            let current = try? CIDRv4(attachment.ipv4Gateway, prefix: attachment.ipv4Address.prefix)
        else {
            return .proceed
        }
        let restartIds = running.map(\.id).contains(containerId) ? running.map(\.id) : [containerId] + running.map(\.id)

        let diagnosis = NetworkDiagnosis.diagnose(
            configuredSubnet: current, hostInterfaces: interfaces, systemSharedAddress: systemSharedAddress,
            containerBridge: nil)

        let candidates: [CIDRv4]
        switch diagnosis {
        case .ok:
            try? history.markApplied(to: current.description)
            return .proceed
        case .undetermined:
            io.write("⚠ container may have no network; run 'container system network check --admin'.\n")
            return .proceed
        case .mismatch(_, let suggested, _):
            candidates = [suggested]
        case .ambiguous(_, let found):
            candidates = found.map(\.cidr)
        }

        // The setting was already changed (choice [2] earlier) but services weren't restarted.
        if let saved = NetworkConfigEditor.subnet(in: userConfigText), saved != current, candidates.contains(saved) {
            io.write(
                "⚠ Network problem: \(containerId) has no network access.\n"
                    + "  container's setting has already been updated to \(NetworkRepairPrompt.range(saved)), "
                    + "but container hasn't been restarted since.\n"
                    + "  Choose [1] to restart now.\n"
                    + NetworkRepairPrompt.restartWarning(running: running))
            guard NetworkRepairPrompt.chooseAction(io: io) == .repairNow else {
                io.write(restartSteps(restartIds))
                return .proceed
            }
            return await repair(from: current, to: saved, containerId: containerId, running: running, repairer: repairer, io: io)
        }

        io.write(
            NetworkRepairPrompt.notification(
                containerId: containerId, diagnosis: diagnosis, running: running,
                recent: history.recentChange(to: current.description, now: now)))

        guard io.isTTY() else {
            io.write(NetworkRepairPrompt.manualSteps(suggested: candidates.count == 1 ? candidates[0] : nil, containerIds: restartIds))
            return .proceed
        }

        let suggested: CIDRv4
        if case .ambiguous(_, let found) = diagnosis {
            guard let picked = NetworkRepairPrompt.chooseNetwork(found, io: io) else {
                io.write(NetworkRepairPrompt.manualSteps(suggested: nil, containerIds: restartIds))
                return .proceed
            }
            suggested = picked
        } else {
            suggested = candidates[0]
        }

        switch NetworkRepairPrompt.chooseAction(io: io) {
        case .repairNow:
            return await repair(from: current, to: suggested, containerId: containerId, running: running, repairer: repairer, io: io)
        case .updateOnly:
            do {
                _ = try repairer.updateOnly(from: current, to: suggested)
                io.write("Saved. container will use \(NetworkRepairPrompt.range(suggested)) after a restart.\n" + restartSteps(restartIds))
            } catch {
                io.write("Could not save the setting: \(error)\n")
                io.write(NetworkRepairPrompt.manualSteps(suggested: suggested, containerIds: restartIds))
            }
            return .proceed
        case .doNothing, nil:
            io.write(NetworkRepairPrompt.manualSteps(suggested: suggested, containerIds: restartIds))
            return .proceed
        }
    }

    private static func repair(
        from current: CIDRv4,
        to suggested: CIDRv4,
        containerId: String,
        running: [RunningContainerInfo],
        repairer: NetworkRepairer,
        io: PromptIO
    ) async -> StartCheckResult {
        io.write("Repairing… (restarting container services)\n")
        switch await repairer.repairNow(from: current, to: suggested, current: containerId, running: running) {
        case .repaired(let restarted, let removed, let stoppedInteractive, let pending):
            if !restarted.isEmpty {
                io.write("Restarted: \(restarted.joined(separator: ", "))\n")
            }
            if !removed.isEmpty {
                io.write("Removed by the restart (started with --rm): \(removed.joined(separator: ", "))\n")
            }
            for id in stoppedInteractive {
                io.write("Stopped \(id). Start it again with: container start -ai \(id)\n")
            }
            return .restartedNeedsRebootstrap(pending)
        case .rolledBack(let reason):
            io.write("⚠ The repair failed and was undone: \(reason)\n")
            return .restartedNeedsRebootstrap(nil)
        case .updatedOnly:
            return .proceed
        }
    }

    private static func restartSteps(_ ids: [String]) -> String {
        "To apply it, run:\n  \(restartCommand)\n" + ids.map { "  container start \($0)\n" }.joined()
    }
}

/// What `container start`/`run` do with the network after bootstrapping a container.
public enum NetworkCheckMode: Equatable, Sendable {
    /// First bootstrap: run the check.
    case check
    /// Bootstrapped again after a repair: confirm it worked.
    case verify(PendingVerification)
    /// Bootstrapped again after a rollback: carry on.
    case skip

    /// The mode for the next bootstrap, or nil to carry on with this one.
    static func next(after result: StartCheckResult) -> NetworkCheckMode? {
        switch result {
        case .proceed:
            return nil
        case .restartedNeedsRebootstrap(let pending):
            return pending.map { .verify($0) } ?? .skip
        }
    }

    /// Runs this mode against a freshly bootstrapped container.
    ///
    /// - Returns: The mode to bootstrap the container again with, or nil to carry on.
    func afterBootstrap(containerId: String, client: ContainerClient, console: Terminal?, log: Logger) async -> NetworkCheckMode? {
        switch self {
        case .check:
            guard let config = try? await ClientHealthCheck.loadContainerSystemConfig() else {
                return nil
            }
            let result = await NetworkStartCheck.run(
                containerId: containerId, client: client, config: config, console: console, log: log)
            return Self.next(after: result)
        case .verify(let pending):
            try? console?.reset()
            defer { try? console?.setraw() }
            return await NetworkStartCheck.verifyAfterRebootstrap(pending, containerId: containerId) ? nil : .skip
        case .skip:
            return nil
        }
    }
}
