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
import SystemPackage
import TOML

/// Edits `[network].subnet` in a user config.toml without disturbing anything else.
///
/// A line-based edit keeps the user's other tables, keys, and comments byte-for-byte,
/// which a decode/encode round trip would not.
public enum NetworkConfigEditor {
    private static let backupPrefix = "config.toml.bak-"

    /// Returns `text` with `[network].subnet` set to `subnet`.
    public static func settingSubnet(_ subnet: CIDRv4, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let lineEnding = text.contains("\r\n") ? "\r" : ""
        let newLine = "subnet = \"\(subnet)\"" + lineEnding

        guard let header = lines.firstIndex(where: isNetworkHeader) else {
            var result = text
            if !result.isEmpty && !result.hasSuffix("\n") {
                result += "\n"
            }
            if !result.isEmpty {
                result += "\n"
            }
            let eol = lineEnding + "\n"
            return result + "[network]" + eol + newLine + "\n"
        }

        let end = lines[(header + 1)...].firstIndex(where: isTableHeader) ?? lines.endIndex
        if let existing = lines[(header + 1)..<end].firstIndex(where: isSubnetKey) {
            lines[existing] = newLine
        } else {
            lines.insert(newLine, at: header + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Reads `[network].subnet`, or nil if it is absent or not a valid CIDR.
    public static func subnet(in text: String) -> CIDRv4? {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: isNetworkHeader) else {
            return nil
        }
        let end = lines[(header + 1)...].firstIndex(where: isTableHeader) ?? lines.endIndex
        guard let line = lines[(header + 1)..<end].first(where: isSubnetKey) else {
            return nil
        }
        let parts = line.split(separator: "\"")
        guard parts.count >= 2 else {
            return nil
        }
        return try? CIDRv4(String(parts[1]))
    }

    /// Backs up `file` (if it exists), then writes the updated subnet, creating parent
    /// directories as needed. Keeps the newest `keepBackups` backups.
    ///
    /// - Returns: The backup path, or nil when there was no file to back up.
    @discardableResult
    public static func write(
        subnet: CIDRv4,
        to file: FilePath,
        now: Date = Date(),
        keepBackups: Int = 5
    ) throws -> FilePath? {
        let fm = FileManager.default
        let dir = file.removingLastComponent()
        try fm.createDirectory(atPath: dir.string, withIntermediateDirectories: true)

        var backup: FilePath? = nil
        let exists = fm.fileExists(atPath: file.string)
        let current = exists ? try String(contentsOfFile: file.string, encoding: .utf8) : ""
        let updated = settingSubnet(subnet, in: current)
        try validate(updated, expecting: subnet, file: file)
        if exists {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let path = dir.appending(backupPrefix + stamp)
            try? fm.removeItem(atPath: path.string)
            try fm.copyItem(atPath: file.string, toPath: path.string)
            backup = path
        }

        try updated.write(toFile: file.string, atomically: true, encoding: .utf8)
        try pruneBackups(in: dir, keep: keepBackups)
        return backup
    }

    /// Restores a backup made by `write` over `file`.
    public static func restore(backup: FilePath, to file: FilePath) throws {
        let contents = try Data(contentsOf: URL(filePath: backup.string))
        try contents.write(to: URL(filePath: file.string), options: .atomic)
    }

    private static func pruneBackups(in dir: FilePath, keep: Int) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.string)
            .filter { $0.hasPrefix(backupPrefix) }
            .sorted()
        for name in names.dropLast(keep) {
            try? FileManager.default.removeItem(atPath: dir.appending(name).string)
        }
    }

    /// Refuses an edit that wouldn't load, e.g. when the user set `network.subnet` as a
    /// dotted key and appending a `[network]` table would define it twice.
    private static func validate(_ text: String, expecting subnet: CIDRv4, file: FilePath) throws {
        struct Probe: Decodable {
            struct Network: Decodable { let subnet: String? }
            let network: Network?
        }
        let decoded = try? TOMLDecoder().decode(Probe.self, from: text)
        guard decoded?.network?.subnet == subnet.description else {
            throw ContainerizationError(
                .invalidArgument,
                message: "could not update \(file) automatically; set [network] subnet = \"\(subnet)\" by hand")
        }
    }

    /// `[network]`, also with inner spaces or a trailing comment.
    private static func isNetworkHeader(_ line: String) -> Bool {
        let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return code.filter { !$0.isWhitespace } == "[network]"
    }

    private static func isTableHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
    }

    private static func isSubnetKey(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("subnet") else {
            return false
        }
        return trimmed.dropFirst("subnet".count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }
}
