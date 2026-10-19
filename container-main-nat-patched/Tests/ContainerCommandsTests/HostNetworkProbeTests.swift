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

struct HostNetworkProbeTests {
    @Test func parsesSharedAddress() throws {
        #expect(HostNetworkProbe.parseSharedAddress("192.168.253.1\n") == (try IPv4Address("192.168.253.1")))
    }

    @Test func parseRejectsGarbage() {
        let output = "The domain/default pair of (com.apple.vmnet, Shared_Net_Address) does not exist"
        #expect(HostNetworkProbe.parseSharedAddress(output) == nil)
    }

    @Test func enumeratesLoopback() throws {
        let lo = HostNetworkProbe.ipv4Interfaces().first { $0.name == "lo0" }
        let loopback = try #require(lo)
        #expect(loopback.address == (try IPv4Address("127.0.0.1")))
        #expect(loopback.prefixLength == 8)
    }
}
