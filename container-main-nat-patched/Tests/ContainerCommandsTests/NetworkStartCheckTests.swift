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

import ContainerResource
import ContainerizationExtras
import Foundation
import SystemPackage
import Testing

import ContainerPersistence

@testable import ContainerCommands

struct NetworkStartCheckTests {
    private let bridge252 = HostInterface(name: "bridge100", address: try! IPv4Address("192.168.252.1"), prefixLength: 24)
    private let bridge253 = HostInterface(name: "bridge101", address: try! IPv4Address("192.168.253.1"), prefixLength: 24)

    private func attachment(gateway: String = "192.168.64.1", variant: String? = "allocationOnly") -> ContainerResource.Attachment {
        ContainerResource.Attachment(
            network: "default", hostname: "kali-gui",
            ipv4Address: try! CIDRv4("192.168.64.2/24"), ipv4Gateway: try! IPv4Address(gateway),
            ipv6Address: nil, macAddress: nil, variant: variant)
    }

    private struct Env {
        let dir: FilePath
        let file: FilePath
        let history: NetworkRepairHistory
        let control: FakeControl
        let repairer: NetworkRepairer
        func config() -> String { (try? String(contentsOfFile: file.string, encoding: .utf8)) ?? "" }
    }

    private func env(_ dir: FilePath, config: String = "") throws -> Env {
        let file = dir.appending("config.toml")
        if !config.isEmpty {
            try config.write(toFile: file.string, atomically: true, encoding: .utf8)
        }
        let history = NetworkRepairHistory(file: dir.appending("network-repair.json"))
        let control = FakeControl()
        return Env(
            dir: dir, file: file, history: history, control: control,
            repairer: NetworkRepairer(control: control, configFile: file, history: history))
    }

    private func evaluate(
        _ e: Env, _ term: FakeTerminal, attachment: ContainerResource.Attachment? = nil, checkOnStart: Bool = true,
        interfaces: [HostInterface]
    ) async -> StartCheckResult {
        await NetworkStartCheck.evaluate(
            containerId: "kali-gui", attachment: attachment ?? self.attachment(), checkOnStart: checkOnStart,
            running: [RunningContainerInfo(id: "kali-gui", interactive: true)],
            userConfigText: e.config(), repairer: e.repairer, history: e.history,
            interfaces: interfaces, io: term.io, now: Date())
    }

    private func tempDir() throws -> FilePath {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FilePath(dir.path)
    }

    @Test func skipsWhenOptedOut() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["1"])
        #expect(await evaluate(e, term, checkOnStart: false, interfaces: [bridge253]) == .proceed)
        #expect(term.output.isEmpty)
    }

    @Test func skipsWhenNotAllocationOnly() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["1"])
        #expect(await evaluate(e, term, attachment: attachment(variant: "reserved"), interfaces: [bridge253]) == .proceed)
        #expect(term.output.isEmpty)
    }

    @Test func okIsSilent() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal()
        let ok = HostInterface(name: "bridge100", address: try IPv4Address("192.168.64.1"), prefixLength: 24)
        #expect(await evaluate(e, term, interfaces: [ok]) == .proceed)
        #expect(term.output.isEmpty)
    }

    @Test func nonTTYPrintsStepsAndChangesNothing() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(tty: false, lines: ["1"])
        #expect(await evaluate(e, term, interfaces: [bridge253]) == .proceed)
        #expect(term.output.contains("⚠ Network problem"))
        #expect(term.output.contains("container system stop && container system start"))
        #expect(term.reads == 0)
        #expect(e.config().isEmpty)
    }

    @Test func choiceTwoUpdatesOnly() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["2"])
        #expect(await evaluate(e, term, interfaces: [bridge253]) == .proceed)
        #expect(NetworkConfigEditor.subnet(in: e.config()) == bridge253.cidr)
        #expect(e.control.calls.isEmpty)
        #expect(term.output.contains("container start kali-gui"))
    }

    @Test func choiceThreeChangesNothing() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: [""])
        #expect(await evaluate(e, term, interfaces: [bridge253]) == .proceed)
        #expect(e.config().isEmpty)
        #expect(e.control.calls.isEmpty)
    }

    @Test func choiceOneRepairsAndAsksForRebootstrap() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["1"])
        let result = await evaluate(e, term, interfaces: [bridge253])
        guard case .restartedNeedsRebootstrap(let pending) = result else {
            Issue.record("expected restartedNeedsRebootstrap, got \(result)")
            return
        }
        #expect(pending?.to == bridge253.cidr)
        #expect(e.control.calls == ["stop", "start"])
    }

    @Test func ambiguousAsksNetworkFirst() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["2", "2"])
        #expect(await evaluate(e, term, interfaces: [bridge252, bridge253]) == .proceed)
        #expect(term.output.contains("Which network is your Mac using for VMs?"))
        #expect(NetworkConfigEditor.subnet(in: e.config()) == bridge253.cidr)
    }

    @Test func ambiguousDontKnowPrintsAdminCheck() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["3"])
        #expect(await evaluate(e, term, interfaces: [bridge252, bridge253]) == .proceed)
        #expect(term.output.contains("container system network check --admin"))
        #expect(e.config().isEmpty)
    }

    @Test func pendingFixOffersRestart() async throws {
        let e = try env(try tempDir(), config: "[network]\nsubnet = \"192.168.253.1/24\"\n")
        let term = FakeTerminal(lines: ["1"])
        let result = await evaluate(e, term, interfaces: [bridge253])
        #expect(term.output.contains("already been updated"))
        #expect(term.output.contains("kali-gui (interactive session will be disconnected)"))
        guard case .restartedNeedsRebootstrap = result else {
            Issue.record("expected restartedNeedsRebootstrap, got \(result)")
            return
        }
        #expect(e.control.calls == ["stop", "start"])
    }

    @Test func undeterminedWarns() async throws {
        let e = try env(try tempDir())
        let term = FakeTerminal(lines: ["1"])
        #expect(await evaluate(e, term, interfaces: []) == .proceed)
        #expect(term.output.contains("container may have no network; run 'container system network check --admin'."))
        #expect(term.reads == 0)
    }
}

struct NetworkCheckModeTests {
    private let pending = PendingVerification(
        from: try! CIDRv4("192.168.64.1/24"), to: try! CIDRv4("192.168.253.1/24"), backup: nil)

    @Test func proceedMeansNoRebootstrap() {
        #expect(NetworkCheckMode.next(after: .proceed) == nil)
    }

    @Test func repairedMeansVerifyOnRebootstrap() {
        #expect(NetworkCheckMode.next(after: .restartedNeedsRebootstrap(pending)) == .verify(pending))
    }

    @Test func rolledBackMeansPlainRebootstrap() {
        #expect(NetworkCheckMode.next(after: .restartedNeedsRebootstrap(nil)) == .skip)
    }
}
