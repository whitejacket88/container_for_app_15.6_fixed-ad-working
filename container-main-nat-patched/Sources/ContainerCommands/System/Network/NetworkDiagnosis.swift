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

/// An IPv4 address assigned to a host network interface.
public struct HostInterface: Sendable, Equatable {
    public let name: String
    public let address: IPv4Address
    public let prefixLength: UInt8

    public init(name: String, address: IPv4Address, prefixLength: UInt8) {
        self.name = name
        self.address = address
        self.prefixLength = prefixLength
    }

    /// The interface's network in config form, e.g. `192.168.253.1/24`.
    public var cidr: CIDRv4 {
        // Prefix lengths come from a netmask, so they are always valid.
        try! CIDRv4(address, prefix: Prefix.ipv4(prefixLength)!)
    }
}

/// Whether the default network's gateway actually exists on the host.
///
/// On macOS 15 the vmnet subnet is chosen system-wide, and `container` can only assume it.
/// If another tool moves the shared range, containers get addresses on a network with no
/// gateway. This compares the configured subnet against the host's bridge interfaces.
public enum NetworkDiagnosis: Sendable, Equatable {
    case ok
    case mismatch(current: CIDRv4, suggested: CIDRv4, evidence: String)
    case ambiguous(current: CIDRv4, candidates: [HostInterface])
    case undetermined(current: CIDRv4)

    /// The gateway `AllocationOnlyVmnetNetwork` hands out for a subnet: `lower + 1`.
    public static func gateway(of subnet: CIDRv4) -> IPv4Address {
        subnet.gateway
    }

    /// - Parameters:
    ///   - systemSharedAddress: `Shared_Net_Address` from the vmnet plist, when known (admin read).
    ///   - containerBridge: the bridge the container's host-side interface joined, when known.
    public static func diagnose(
        configuredSubnet: CIDRv4,
        hostInterfaces: [HostInterface],
        systemSharedAddress: IPv4Address?,
        containerBridge: String?
    ) -> NetworkDiagnosis {
        let gateway = gateway(of: configuredSubnet)
        let bridges = hostInterfaces.filter { $0.name.hasPrefix("bridge") && isPrivate($0.address) }

        if let shared = systemSharedAddress {
            if shared == gateway {
                return .ok
            }
            let prefix = bridges.first { $0.address == shared }?.prefixLength ?? 24
            let suggested = HostInterface(name: "vmnet", address: shared, prefixLength: prefix).cidr
            return .mismatch(
                current: configuredSubnet, suggested: suggested,
                evidence: "macOS shared VM network is \(shared)")
        }

        if let name = containerBridge, let bridge = bridges.first(where: { $0.name == name }) {
            if bridge.address == gateway {
                return .ok
            }
            return .mismatch(
                current: configuredSubnet, suggested: bridge.cidr,
                evidence: "the container joined \(bridge.name) (\(bridge.address))")
        }

        if hostInterfaces.contains(where: { $0.address == gateway }) {
            return .ok
        }

        switch bridges.count {
        case 0:
            return .undetermined(current: configuredSubnet)
        case 1:
            let bridge = bridges[0]
            return .mismatch(
                current: configuredSubnet, suggested: bridge.cidr,
                evidence: "the only VM bridge is \(bridge.name) (\(bridge.address))")
        default:
            return .ambiguous(current: configuredSubnet, candidates: bridges)
        }
    }

    private static func isPrivate(_ address: IPv4Address) -> Bool {
        let v = address.value
        return v & 0xFFFF_0000 == 0xC0A8_0000  // 192.168.0.0/16
            || v & 0xFFF0_0000 == 0xAC10_0000  // 172.16.0.0/12
            || v & 0xFF00_0000 == 0x0A00_0000  // 10.0.0.0/8
    }
}
