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

struct NetworkDiagnosisTests {
    private func b(_ name: String, _ ip: String, _ len: UInt8 = 24) throws -> HostInterface {
        HostInterface(name: name, address: try IPv4Address(ip), prefixLength: len)
    }

    private let configured64 = try! CIDRv4("192.168.64.1/24")

    @Test func okWhenGatewayPresent() throws {
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: configured64,
            hostInterfaces: [try b("bridge100", "192.168.64.1")],
            systemSharedAddress: nil,
            containerBridge: nil)
        #expect(result == .ok)
    }

    @Test func mismatchSingleBridge() throws {
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: configured64,
            hostInterfaces: [try b("bridge101", "192.168.253.1"), try b("en0", "192.168.1.20")],
            systemSharedAddress: nil,
            containerBridge: nil)
        guard case .mismatch(let current, let suggested, _) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(current == configured64)
        #expect(suggested == (try CIDRv4("192.168.253.1/24")))
    }

    @Test func twoBridgesNoSignalIsAmbiguous() throws {
        let bridges = [try b("bridge100", "192.168.252.1"), try b("bridge101", "192.168.253.1")]
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: configured64, hostInterfaces: bridges,
            systemSharedAddress: nil, containerBridge: nil)
        #expect(result == .ambiguous(current: configured64, candidates: bridges))
    }

    @Test func systemAddressWins() throws {
        let bridges = [try b("bridge100", "192.168.252.1"), try b("bridge101", "192.168.253.1")]
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: configured64, hostInterfaces: bridges,
            systemSharedAddress: try IPv4Address("192.168.253.1"), containerBridge: nil)
        guard case .mismatch(_, let suggested, _) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(suggested == (try CIDRv4("192.168.253.1/24")))
    }

    @Test func containerBridgeWins() throws {
        let bridges = [try b("bridge100", "192.168.252.1"), try b("bridge101", "192.168.253.1")]
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: configured64, hostInterfaces: bridges,
            systemSharedAddress: nil, containerBridge: "bridge100")
        guard case .mismatch(_, let suggested, _) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(suggested == (try CIDRv4("192.168.252.1/24")))
    }

    @Test func okRejectedWhenSystemAddressDisagrees() throws {
        let bridges = [try b("bridge100", "192.168.252.1"), try b("bridge101", "192.168.253.1")]
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: try CIDRv4("192.168.252.1/24"), hostInterfaces: bridges,
            systemSharedAddress: try IPv4Address("192.168.253.1"), containerBridge: nil)
        guard case .mismatch(_, let suggested, _) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(suggested == (try CIDRv4("192.168.253.1/24")))
    }

    @Test func noBridgesIsUndetermined() throws {
        let result = NetworkDiagnosis.diagnose(
            configuredSubnet: configured64, hostInterfaces: [try b("en0", "10.0.0.5")],
            systemSharedAddress: nil, containerBridge: nil)
        #expect(result == .undetermined(current: configured64))
    }

    @Test func gatewayIsLowerPlusOne() throws {
        let expected = try IPv4Address("192.168.253.1")
        #expect(NetworkDiagnosis.gateway(of: try CIDRv4("192.168.253.0/24")) == expected)
        #expect(NetworkDiagnosis.gateway(of: try CIDRv4("192.168.253.1/24")) == expected)
    }
}
