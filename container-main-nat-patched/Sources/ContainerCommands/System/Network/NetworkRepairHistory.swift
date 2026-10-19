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

import Foundation
import SystemPackage

/// One subnet change made through the network repair prompt.
public struct NetworkRepairRecord: Codable, Sendable, Equatable {
    public let date: Date
    public let from: String
    public let to: String
    /// The prompt choice: 1 (repair now) or 2 (update only).
    public let choice: Int
    /// True after "update only" until a later check sees the running network use `to`.
    public var pending: Bool

    public init(date: Date, from: String, to: String, choice: Int, pending: Bool) {
        self.date = date
        self.from = from
        self.to = to
        self.choice = choice
        self.pending = pending
    }
}

/// The repair log kept at `<appRoot>/network-repair.json`.
public struct NetworkRepairHistory: Sendable {
    private static let maxRecords = 20
    private let file: FilePath

    public init(file: FilePath) {
        self.file = file
    }

    /// Records oldest first; empty if the file is missing or unreadable.
    public func load() -> [NetworkRepairRecord] {
        guard let data = try? Data(contentsOf: URL(filePath: file.string)) else {
            return []
        }
        return (try? Self.decoder.decode([NetworkRepairRecord].self, from: data)) ?? []
    }

    public func append(_ record: NetworkRepairRecord) throws {
        try save((load() + [record]).suffix(Self.maxRecords))
    }

    public func markApplied(to cidr: String) throws {
        let records = load().map { record in
            var record = record
            if record.to == cidr {
                record.pending = false
            }
            return record
        }
        try save(records)
    }

    /// The latest record that set the range to `cidr` within `window` seconds of `now`.
    public func recentChange(to cidr: String, now: Date, window: TimeInterval = 600) -> NetworkRepairRecord? {
        load().last { $0.to == cidr && now.timeIntervalSince($0.date) <= window }
    }

    private func save<C: Collection>(_ records: C) throws where C.Element == NetworkRepairRecord {
        try FileManager.default.createDirectory(
            atPath: file.removingLastComponent().string, withIntermediateDirectories: true)
        try Self.encoder.encode(Array(records)).write(to: URL(filePath: file.string), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
