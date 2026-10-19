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
import ContainerizationError
import ContainerizationExtras
import Foundation
import SystemPackage

/// The system actions a network repair needs, injectable for tests.
public protocol ContainerSystemControl: Sendable {
    func stopSystem() async throws
    func startSystem() async throws
    /// Starts an existing container detached.
    func startContainer(id: String) async throws
    func exists(id: String) async -> Bool
    func runningGateway(of id: String) async throws -> IPv4Address?
    func hostInterfaces() -> [HostInterface]
    /// Whether the host can reach the container's address, proving it is on the right
    /// bridge (a wrong bridge can still hold the gateway address).
    func hostCanReach(id: String) async -> Bool
}

/// A repair that has been applied but not yet confirmed against a running container.
public struct PendingVerification: Equatable, Sendable {
    public let from: CIDRv4
    public let to: CIDRv4
    /// The config backup to restore if verification fails; nil if there was no config file.
    public let backup: FilePath?
}

public enum RepairOutcome: Equatable, Sendable {
    case repaired(restarted: [String], removed: [String], stoppedInteractive: [String], pending: PendingVerification)
    case updatedOnly(backup: FilePath?)
    case rolledBack(reason: String)
}

/// Applies a subnet change to the user config and restarts `container` so it takes effect.
///
/// The container being started is never restarted here: its `start`/`run` command
/// bootstraps it again and then calls `verify`, so an interactive session stays attached.
public struct NetworkRepairer: Sendable {
    private let control: any ContainerSystemControl
    private let configFile: FilePath
    private let history: NetworkRepairHistory

    public init(control: any ContainerSystemControl, configFile: FilePath, history: NetworkRepairHistory) {
        self.control = control
        self.configFile = configFile
        self.history = history
    }

    /// Writes the new subnet without restarting anything.
    public func updateOnly(from: CIDRv4, to: CIDRv4) throws -> RepairOutcome {
        let backup = try NetworkConfigEditor.write(subnet: to, to: configFile)
        try history.append(.init(date: Date(), from: from.description, to: to.description, choice: 2, pending: true))
        return .updatedOnly(backup: backup)
    }

    /// Writes the new subnet, restarts services, and restarts the other running containers.
    /// Rolls back if the services fail to come back up.
    public func repairNow(
        from: CIDRv4,
        to: CIDRv4,
        current: String,
        running: [RunningContainerInfo]
    ) async -> RepairOutcome {
        let backup: FilePath?
        do {
            backup = try NetworkConfigEditor.write(subnet: to, to: configFile)
            try history.append(.init(date: Date(), from: from.description, to: to.description, choice: 1, pending: true))
        } catch {
            return .rolledBack(reason: "could not update \(configFile): \(error)")
        }

        let pending = PendingVerification(from: from, to: to, backup: backup)
        do {
            try await control.stopSystem()
            try await control.startSystem()
        } catch {
            await rollBack(pending)
            return .rolledBack(reason: "container services did not restart: \(error)")
        }

        var restarted: [String] = []
        var removed: [String] = []
        var stoppedInteractive: [String] = []
        for container in running where container.id != current {
            if container.interactive {
                stoppedInteractive.append(container.id)
            } else if await control.exists(id: container.id) {
                do {
                    try await control.startContainer(id: container.id)
                    restarted.append(container.id)
                } catch {
                    stoppedInteractive.append(container.id)
                }
            } else {
                removed.append(container.id)
            }
        }
        return .repaired(restarted: restarted, removed: removed, stoppedInteractive: stoppedInteractive, pending: pending)
    }

    /// Checks that container `id`'s gateway now exists on the host and that the host can
    /// reach the container. On failure, restores the previous config and restarts services again.
    ///
    /// - Returns: true if the repair worked; false if it was rolled back.
    public func verify(_ pending: PendingVerification, id: String) async -> Bool {
        let gateway = try? await control.runningGateway(of: id)
        if let gateway, control.hostInterfaces().contains(where: { $0.address == gateway }),
            await control.hostCanReach(id: id)
        {
            try? history.markApplied(to: pending.to.description)
            return true
        }
        await rollBack(pending)
        return false
    }

    private func rollBack(_ pending: PendingVerification) async {
        if let backup = pending.backup {
            try? NetworkConfigEditor.restore(backup: backup, to: configFile)
        } else {
            try? FileManager.default.removeItem(atPath: configFile.string)
        }
        try? await control.stopSystem()
        try? await control.startSystem()
    }
}

/// Runs the same `container` binary for system actions, so restarts behave exactly like
/// `container system stop` / `container system start`.
public struct CLISystemControl: ContainerSystemControl {
    public init() {}

    public func stopSystem() async throws {
        try run(["system", "stop"])
    }

    public func startSystem() async throws {
        try run(["system", "start", "--disable-kernel-install"])
    }

    public func startContainer(id: String) async throws {
        try run(["start", id])
    }

    public func exists(id: String) async -> Bool {
        (try? await ContainerClient().get(id: id)) != nil
    }

    public func runningGateway(of id: String) async throws -> IPv4Address? {
        try await ContainerClient().get(id: id).networks.first?.ipv4Gateway
    }

    public func hostInterfaces() -> [HostInterface] {
        HostNetworkProbe.ipv4Interfaces()
    }

    public func hostCanReach(id: String) async -> Bool {
        guard let address = try? await ContainerClient().get(id: id).networks.first?.ipv4Address.address else {
            return false
        }
        // The VM may still be bringing its interface up, so allow a few seconds.
        for _ in 0..<5 {
            let ping = Process()
            ping.executableURL = URL(filePath: "/sbin/ping")
            ping.arguments = ["-c", "1", "-t", "1", "\(address)"]
            ping.standardOutput = FileHandle.nullDevice
            ping.standardError = FileHandle.nullDevice
            guard (try? ping.run()) != nil else {
                return false
            }
            ping.waitUntilExit()
            if ping.terminationStatus == 0 {
                return true
            }
        }
        return false
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "container \(arguments.joined(separator: " ")) failed: \(String(decoding: data, as: UTF8.self))")
        }
    }
}
