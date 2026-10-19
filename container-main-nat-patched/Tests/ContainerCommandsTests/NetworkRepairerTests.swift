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

import ContainerizationError
import ContainerizationExtras
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ContainerCommands

/// Records the system actions the repairer takes; failures and state are configurable.
final class FakeControl: ContainerSystemControl {
    struct State {
        var calls: [String] = []
        var failStartSystemTimes = 0
        var missing: Set<String> = []
        var gateway: IPv4Address? = nil
        var interfaces: [HostInterface] = []
        var reachable = true
    }
    let state: Mutex<State>

    init(_ state: State = State()) {
        self.state = Mutex(state)
    }

    var calls: [String] { state.withLock { $0.calls } }

    func stopSystem() async throws {
        state.withLock { $0.calls.append("stop") }
    }

    func startSystem() async throws {
        try state.withLock { s in
            s.calls.append("start")
            if s.failStartSystemTimes > 0 {
                s.failStartSystemTimes -= 1
                throw ContainerizationError(.internalError, message: "start failed")
            }
        }
    }

    func startContainer(id: String) async throws {
        state.withLock { $0.calls.append("startContainer(\(id))") }
    }

    func exists(id: String) async -> Bool {
        state.withLock { !$0.missing.contains(id) }
    }

    func runningGateway(of id: String) async throws -> IPv4Address? {
        state.withLock { $0.gateway }
    }

    func hostInterfaces() -> [HostInterface] {
        state.withLock { $0.interfaces }
    }

    func hostCanReach(id: String) async -> Bool {
        state.withLock { $0.reachable }
    }
}

struct NetworkRepairerTests {
    private let from = try! CIDRv4("192.168.64.1/24")
    private let to = try! CIDRv4("192.168.253.1/24")
    private let original = "[build]\ncpus = 2\n"
    private let bridge = HostInterface(name: "bridge101", address: try! IPv4Address("192.168.253.1"), prefixLength: 24)

    private func setUp(_ dir: FilePath, _ control: FakeControl) throws -> (NetworkRepairer, FilePath, NetworkRepairHistory) {
        let file = dir.appending("config.toml")
        try original.write(toFile: file.string, atomically: true, encoding: .utf8)
        let history = NetworkRepairHistory(file: dir.appending("network-repair.json"))
        return (NetworkRepairer(control: control, configFile: file, history: history), file, history)
    }

    private func read(_ file: FilePath) throws -> String {
        try String(contentsOfFile: file.string, encoding: .utf8)
    }

    @Test func updateOnlyWritesAndRecordsPending() throws {
        try withTempDir { dir in
            let control = FakeControl()
            let (repairer, file, history) = try setUp(dir, control)
            let outcome = try repairer.updateOnly(from: from, to: to)
            guard case .updatedOnly(let backup) = outcome else {
                Issue.record("expected updatedOnly, got \(outcome)")
                return
            }
            #expect(backup != nil)
            #expect(try read(file).contains("subnet = \"192.168.253.1/24\""))
            #expect(history.load().map(\.pending) == [true])
            #expect(control.calls.isEmpty)
        }
    }

    @Test func repairNowRestartsOtherContainersOnly() async throws {
        let dir = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let control = FakeControl()
        let (repairer, file, _) = try setUp(dir, control)

        let outcome = await repairer.repairNow(
            from: from, to: to, current: "cur",
            running: [
                RunningContainerInfo(id: "cur", interactive: false),
                RunningContainerInfo(id: "a", interactive: false),
                RunningContainerInfo(id: "b", interactive: true),
            ])
        guard case .repaired(let restarted, let removed, let stoppedInteractive, _) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        #expect(control.calls == ["stop", "start", "startContainer(a)"])
        #expect(restarted == ["a"])
        #expect(removed.isEmpty)
        #expect(stoppedInteractive == ["b"])
        #expect(try read(file).contains("subnet = \"192.168.253.1/24\""))
    }

    @Test func repairNowReportsRemoved() async throws {
        let dir = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let control = FakeControl(.init(missing: ["a"]))
        let (repairer, _, _) = try setUp(dir, control)

        let outcome = await repairer.repairNow(
            from: from, to: to, current: "cur", running: [RunningContainerInfo(id: "a", interactive: false)])
        guard case .repaired(let restarted, let removed, _, _) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        #expect(restarted.isEmpty)
        #expect(removed == ["a"])
    }

    @Test func repairNowRollsBackOnStartFailure() async throws {
        let dir = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let control = FakeControl(.init(failStartSystemTimes: 1))
        let (repairer, file, _) = try setUp(dir, control)

        let outcome = await repairer.repairNow(from: from, to: to, current: "cur", running: [])
        guard case .rolledBack = outcome else {
            Issue.record("expected rolledBack, got \(outcome)")
            return
        }
        #expect(try read(file) == original)
        #expect(control.calls == ["stop", "start", "stop", "start"])
    }

    @Test func verifySucceedsMarksApplied() async throws {
        let dir = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let control = FakeControl(.init(gateway: try IPv4Address("192.168.253.1"), interfaces: [bridge]))
        let (repairer, file, history) = try setUp(dir, control)

        let outcome = await repairer.repairNow(from: from, to: to, current: "cur", running: [])
        guard case .repaired(_, _, _, let pending) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        #expect(await repairer.verify(pending, id: "cur") == true)
        #expect(history.load().map(\.pending) == [false])
        #expect(try read(file).contains("192.168.253.1/24"))
    }

    @Test func verifyFailureRollsBack() async throws {
        let dir = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let control = FakeControl(.init(gateway: try IPv4Address("192.168.253.1"), interfaces: []))
        let (repairer, file, _) = try setUp(dir, control)

        let outcome = await repairer.repairNow(from: from, to: to, current: "cur", running: [])
        guard case .repaired(_, _, _, let pending) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        #expect(await repairer.verify(pending, id: "cur") == false)
        #expect(try read(file) == original)
        #expect(control.calls == ["stop", "start", "stop", "start"])
    }

    /// A wrong pick (e.g. the Multipass bridge) still has its gateway on the host, so only
    /// reaching the container itself proves the repair worked.
    @Test func verifyFailsWhenContainerUnreachable() async throws {
        let dir = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let control = FakeControl(.init(gateway: try IPv4Address("192.168.253.1"), interfaces: [bridge], reachable: false))
        let (repairer, file, _) = try setUp(dir, control)

        let outcome = await repairer.repairNow(from: from, to: to, current: "cur", running: [])
        guard case .repaired(_, _, _, let pending) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        #expect(await repairer.verify(pending, id: "cur") == false)
        #expect(try read(file) == original)
    }
}
