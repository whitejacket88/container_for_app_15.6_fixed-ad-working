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
import Testing

@testable import ContainerCommands

struct SystemNetworkCheckTests {
    private let current = try! CIDRv4("192.168.64.1/24")
    private let suggested = try! CIDRv4("192.168.253.1/24")

    @Test func exitCodes() {
        typealias Check = Application.SystemNetworkCheck
        #expect(Check.exitCode(for: .ok, fixed: false) == 0)
        #expect(Check.exitCode(for: .mismatch(current: current, suggested: suggested, evidence: ""), fixed: false) == 1)
        #expect(Check.exitCode(for: .mismatch(current: current, suggested: suggested, evidence: ""), fixed: true) == 0)
        #expect(Check.exitCode(for: .ambiguous(current: current, candidates: []), fixed: false) == 2)
        #expect(Check.exitCode(for: .undetermined(current: current), fixed: false) == 2)
    }

    @Test func helpListsFlags() {
        let help = Application.SystemNetworkCheck.helpMessage()
        #expect(help.contains("--admin"))
        #expect(help.contains("--fix"))
        #expect(help.contains("--subnet"))
    }

    @Test func registeredUnderSystem() {
        let names = Application.SystemCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("network"))
    }
}
