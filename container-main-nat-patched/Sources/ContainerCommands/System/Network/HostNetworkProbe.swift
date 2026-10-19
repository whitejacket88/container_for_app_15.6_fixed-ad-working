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
import Darwin
import Foundation

/// Reads the host's network state for `NetworkDiagnosis`.
public enum HostNetworkProbe {
    static let vmnetPlist = "/Library/Preferences/SystemConfiguration/com.apple.vmnet"

    /// All IPv4 addresses on host interfaces. Needs no privileges.
    public static func ipv4Interfaces() -> [HostInterface] {
        var addrList: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&addrList) == 0, let start = addrList else {
            return []
        }
        defer { freeifaddrs(start) }
        return sequence(first: start, next: { $0.pointee.ifa_next })
            .compactMap { i -> HostInterface? in
                guard
                    let sa = i.pointee.ifa_addr, sa.pointee.sa_family == AF_INET,
                    let mask = i.pointee.ifa_netmask
                else { return nil }
                let addr = UnsafeRawPointer(sa).load(as: sockaddr_in.self).sin_addr.s_addr
                let bits = UnsafeRawPointer(mask).load(as: sockaddr_in.self).sin_addr.s_addr
                return HostInterface(
                    name: String(cString: i.pointee.ifa_name),
                    address: IPv4Address(UInt32(bigEndian: addr)),
                    prefixLength: UInt8(bits.nonzeroBitCount))
            }
    }

    /// Parses `defaults read … Shared_Net_Address` output.
    public static func parseSharedAddress(_ defaultsOutput: String) -> IPv4Address? {
        try? IPv4Address(defaultsOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Reads the Mac's shared vmnet address. The plist is root-only, so this runs
    /// `sudo`, which may prompt for a password on the user's terminal.
    ///
    /// - Returns: nil when the key is absent (macOS then uses its default range).
    public static func readSystemSharedAddress() throws -> IPv4Address? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/sudo")
        process.arguments = ["/usr/bin/defaults", "read", vmnetPlist, "Shared_Net_Address"]
        process.standardOutput = output
        process.standardError = errors  // sudo prompts on /dev/tty, not stderr
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if errorText.contains("does not exist") {
                return nil
            }
            throw ContainerizationError(
                .internalError,
                message: "failed to read \(vmnetPlist): \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parseSharedAddress(String(decoding: data, as: UTF8.self))
    }
}
