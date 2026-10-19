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

import ContainerizationExtras
import Foundation
import Synchronization
import SystemPackage
import Testing

@testable import ContainerCommands

/// Runs `body` with a fresh temporary directory, removed afterwards.
func withTempDir(_ body: (FilePath) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(FilePath(dir.path))
}

/// Scripted terminal: serves `lines` to readLine and records everything written.
final class FakeTerminal: Sendable {
    private struct State {
        var lines: [String]
        var reads = 0
        var output = ""
    }
    private let state: Mutex<State>
    let tty: Bool

    init(tty: Bool = true, lines: [String] = []) {
        self.tty = tty
        self.state = Mutex(State(lines: lines))
    }

    var reads: Int { state.withLock { $0.reads } }
    var output: String { state.withLock { $0.output } }

    var io: PromptIO {
        PromptIO(
            isTTY: { self.tty },
            readLine: {
                self.state.withLock { s in
                    s.reads += 1
                    return s.lines.isEmpty ? nil : s.lines.removeFirst()
                }
            },
            write: { text in self.state.withLock { $0.output += text } }
        )
    }
}

struct NetworkRepairPromptTests {
    private let current = try! CIDRv4("192.168.64.1/24")
    private let suggested = try! CIDRv4("192.168.253.1/24")
    private let candidates = [
        HostInterface(name: "bridge100", address: try! IPv4Address("192.168.252.1"), prefixLength: 24),
        HostInterface(name: "bridge101", address: try! IPv4Address("192.168.253.1"), prefixLength: 24),
    ]

    @Test func nonTTYNeverReadsOrWrites() {
        let term = FakeTerminal(tty: false, lines: ["1"])
        #expect(NetworkRepairPrompt.chooseAction(io: term.io) == nil)
        #expect(NetworkRepairPrompt.chooseNetwork(candidates, io: term.io) == nil)
        #expect(term.reads == 0)
    }

    @Test func enterMeansDoNothing() {
        #expect(NetworkRepairPrompt.chooseAction(io: FakeTerminal(lines: [""]).io) == .doNothing)
    }

    @Test func choiceOneAndTwo() {
        #expect(NetworkRepairPrompt.chooseAction(io: FakeTerminal(lines: ["1"]).io) == .repairNow)
        #expect(NetworkRepairPrompt.chooseAction(io: FakeTerminal(lines: ["2"]).io) == .updateOnly)
        #expect(NetworkRepairPrompt.chooseAction(io: FakeTerminal(lines: ["3"]).io) == .doNothing)
    }

    @Test func choiceLabelsShown() {
        let term = FakeTerminal(lines: ["3"])
        _ = NetworkRepairPrompt.chooseAction(io: term.io)
        #expect(term.output.contains("[1] Repair automatically now"))
        #expect(term.output.contains("[2] Update the setting only. I'll restart later"))
        #expect(term.output.contains("[3] Do nothing"))
    }

    @Test func invalidThenGiveUp() {
        let term = FakeTerminal(lines: ["x", "y", "z", "1"])
        #expect(NetworkRepairPrompt.chooseAction(io: term.io) == .doNothing)
        #expect(term.reads == 3)
    }

    @Test func endOfInputMeansDoNothing() {
        #expect(NetworkRepairPrompt.chooseAction(io: FakeTerminal(lines: []).io) == .doNothing)
    }

    @Test func chooseNetworkPicksSecond() {
        #expect(NetworkRepairPrompt.chooseNetwork(candidates, io: FakeTerminal(lines: ["2"]).io) == suggested)
        #expect(NetworkRepairPrompt.chooseNetwork(candidates, io: FakeTerminal(lines: ["3"]).io) == nil)
        #expect(NetworkRepairPrompt.chooseNetwork(candidates, io: FakeTerminal(lines: [""]).io) == nil)
    }

    @Test func notificationListsAllRunning() {
        let text = NetworkRepairPrompt.notification(
            containerId: "kali-gui",
            diagnosis: .mismatch(current: current, suggested: suggested, evidence: "e"),
            running: [
                RunningContainerInfo(id: "kali-gui", interactive: true),
                RunningContainerInfo(id: "web", interactive: false),
            ],
            recent: nil)
        #expect(text.hasPrefix("⚠ Network problem: kali-gui has no network access."))
        #expect(text.contains("192.168.64.x"))
        #expect(text.contains("192.168.253.x"))
        #expect(text.contains("kali-gui (interactive session will be disconnected)"))
        #expect(text.contains("web"))
        #expect(text.contains("Containers started with --rm will be removed rather than restarted."))
        #expect(text.contains("Run 'container system network check' for details."))
    }

    @Test func notificationMentionsRecentChange() {
        let record = NetworkRepairRecord(
            date: Date().addingTimeInterval(-180), from: "192.168.252.1/24", to: "192.168.64.1/24", choice: 1, pending: false)
        let text = NetworkRepairPrompt.notification(
            containerId: "a", diagnosis: .mismatch(current: current, suggested: suggested, evidence: "e"),
            running: [], recent: record)
        #expect(text.contains("3 minutes ago"))
    }

    @Test func manualStepsListsCommands() {
        let text = NetworkRepairPrompt.manualSteps(suggested: suggested, containerIds: ["kali-gui"])
        #expect(text.contains("subnet = \"192.168.253.1/24\""))
        #expect(text.contains("container system stop && container system start"))
        #expect(text.contains("container start kali-gui"))
    }

    @Test func historyRecentWindow() throws {
        try withTempDir { dir in
            let history = NetworkRepairHistory(file: dir.appending("network-repair.json"))
            let now = Date()
            try history.append(NetworkRepairRecord(date: now.addingTimeInterval(-300), from: "a", to: "192.168.64.1/24", choice: 1, pending: false))
            #expect(history.recentChange(to: "192.168.64.1/24", now: now) != nil)
            #expect(history.recentChange(to: "192.168.64.1/24", now: now.addingTimeInterval(400)) == nil)
        }
    }

    @Test func historyMarkApplied() throws {
        try withTempDir { dir in
            let history = NetworkRepairHistory(file: dir.appending("network-repair.json"))
            try history.append(NetworkRepairRecord(date: Date(), from: "a", to: "192.168.253.1/24", choice: 2, pending: true))
            try history.markApplied(to: "192.168.253.1/24")
            #expect(history.load().first?.pending == false)
        }
    }

    @Test func historyMissingFileIsEmpty() {
        let history = NetworkRepairHistory(file: FilePath("/nonexistent/network-repair.json"))
        #expect(history.load().isEmpty)
    }
}
