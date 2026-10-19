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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationExtras
import Foundation

extension Application {
    public struct SystemNetworkCheck: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Check that containers can reach the network, and offer to fix it"
        )

        @Flag(help: "Also read the Mac's VM network setting (asks for your password)")
        var admin = false

        @Flag(help: "Repair without asking")
        var fix = false

        @Option(help: "Use this network instead of the detected one, e.g. 192.168.253.1/24")
        var subnet: String? = nil

        @OptionGroup
        public var logOptions: Flags.Logging

        static let defaultSubnet = try! CIDRv4("192.168.64.1/24")

        /// 0 ok, 1 mismatch left unfixed, 2 ambiguous or undetermined.
        static func exitCode(for diagnosis: NetworkDiagnosis, fixed: Bool) -> Int32 {
            switch diagnosis {
            case .ok: return 0
            case .mismatch: return fixed ? 0 : 1
            case .ambiguous, .undetermined: return fixed ? 0 : 2
            }
        }

        public func run() async throws {
            if #available(macOS 26, *) {
                print("Networking is managed automatically by macOS 26 or later.")
                return
            }
            do {
                try await check()
            } catch let error as ArgumentParser.ExitCode {
                throw error
            } catch {
                print("Error: \(error)")
                throw ArgumentParser.ExitCode(3)
            }
        }

        private func check() async throws {
            let override = try subnet.map { try CIDRv4($0) }
            let config = try await ClientHealthCheck.loadContainerSystemConfig()
            let client = ContainerClient()
            let control = CLISystemControl()
            let running = try await client.list(filters: ContainerListFilters(status: .running))
            let probe = running.first { $0.networks.first?.variant == "allocationOnly" }
            let attachment = probe?.networks.first
            let current =
                attachment.flatMap { try? CIDRv4($0.ipv4Gateway, prefix: $0.ipv4Address.prefix) }
                ?? config.network.subnet ?? Self.defaultSubnet
            let shared = admin ? try HostNetworkProbe.readSystemSharedAddress() : nil
            let interfaces = control.hostInterfaces()
            let diagnosis = NetworkDiagnosis.diagnose(
                configuredSubnet: current, hostInterfaces: interfaces, systemSharedAddress: shared, containerBridge: nil)

            print("container's network:  \(current) (gateway \(NetworkDiagnosis.gateway(of: current)))")
            if admin {
                print("Mac's VM network:     \(shared.map { "\($0)" } ?? "not set (macOS default 192.168.64.1)")")
            }
            let bridges = interfaces.filter { $0.name.hasPrefix("bridge") }
            print("VM bridges on this Mac: \(bridges.isEmpty ? "none (no VMs running)" : bridges.map { "\($0.name) \($0.cidr)" }.joined(separator: ", "))")
            for container in running {
                print("  \(container.id): \(reachable(container.id) ? "reachable" : "no network")")
            }
            print("Result: \(verdict(diagnosis))")

            guard diagnosis != .ok else {
                return
            }

            let configFile = ConfigurationLoader.configurationFile(.home)
            let history = NetworkRepairHistory(file: NetworkStartCheck.historyFile())
            let repairer = NetworkRepairer(control: control, configFile: configFile, history: history)
            let runningInfo = running.map { RunningContainerInfo(id: $0.id, interactive: $0.configuration.initProcess.terminal) }

            if fix {
                let target: CIDRv4
                if let override {
                    target = override
                } else if case .mismatch(_, let suggested, _) = diagnosis {
                    target = suggested
                } else {
                    if case .ambiguous(_, let candidates) = diagnosis {
                        print("More than one possible network: \(candidates.map { "\($0.cidr)" }.joined(separator: ", "))")
                    }
                    print("Re-run with --subnet <cidr>, or with --admin to read the Mac's setting.")
                    throw ArgumentParser.ExitCode(2)
                }
                try await repairAll(repairer, from: current, to: target, running: runningInfo)
                return
            }

            guard let probe, let attachment else {
                print(NetworkRepairPrompt.manualSteps(suggested: override, containerIds: []))
                throw ArgumentParser.ExitCode(Self.exitCode(for: diagnosis, fixed: false))
            }

            let result = await NetworkStartCheck.evaluate(
                containerId: probe.id, attachment: attachment, checkOnStart: true, running: runningInfo,
                userConfigText: (try? String(contentsOfFile: configFile.string, encoding: .utf8)) ?? "",
                repairer: repairer, history: history, interfaces: interfaces, io: .standard, now: Date(),
                systemSharedAddress: shared)
            guard case .restartedNeedsRebootstrap(let pending) = result else {
                throw ArgumentParser.ExitCode(Self.exitCode(for: diagnosis, fixed: false))
            }
            if probe.configuration.initProcess.terminal {
                print("Start \(probe.id) again with: container start -ai \(probe.id)")
                return
            }
            try await control.startContainer(id: probe.id)
            if let pending, !(await NetworkStartCheck.verifyAfterRebootstrap(pending, containerId: probe.id)) {
                throw ArgumentParser.ExitCode(3)
            }
        }

        private func repairAll(_ repairer: NetworkRepairer, from: CIDRv4, to: CIDRv4, running: [RunningContainerInfo]) async throws {
            print("Repairing… (restarting container services)")
            switch await repairer.repairNow(from: from, to: to, current: "", running: running) {
            case .repaired(let restarted, let removed, let stoppedInteractive, let pending):
                if !removed.isEmpty {
                    print("Removed by the restart (started with --rm): \(removed.joined(separator: ", "))")
                }
                for id in stoppedInteractive {
                    print("Stopped \(id). Start it again with: container start -ai \(id)")
                }
                guard let first = restarted.first else {
                    print("container now uses \(to). Start a container to confirm it has network access.")
                    return
                }
                if !(await NetworkStartCheck.verifyAfterRebootstrap(pending, containerId: first)) {
                    throw ArgumentParser.ExitCode(3)
                }
            case .rolledBack(let reason):
                print("⚠ The repair failed and was undone: \(reason)")
                throw ArgumentParser.ExitCode(3)
            case .updatedOnly:
                return
            }
        }

        private func verdict(_ diagnosis: NetworkDiagnosis) -> String {
            switch diagnosis {
            case .ok:
                return "OK. Containers can reach their gateway."
            case .mismatch(_, let suggested, let evidence):
                return "Problem. container should use \(suggested) (\(evidence))."
            case .ambiguous(_, let candidates):
                return "Problem. The gateway is missing, and more than one network could be right: "
                    + candidates.map { "\($0.cidr)" }.joined(separator: ", ")
            case .undetermined:
                return "Unknown. No VM network is up; start a container or re-run with --admin."
            }
        }

        /// Whether the container can resolve a public name, via `container exec`.
        private func reachable(_ id: String) -> Bool {
            let process = Process()
            process.executableURL = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
            process.arguments = [
                "exec", id, "sh", "-c",
                "getent hosts http.kali.org >/dev/null 2>&1 || nslookup http.kali.org >/dev/null 2>&1",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else {
                return false
            }
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        }
    }
}
