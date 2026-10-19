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

import ContainerTestSupport
import ContainerizationExtras
import Foundation
import SystemPackage
import Testing

@testable import ContainerPersistence

struct NetworkConfigEditorTests {
    private let new = try! CIDRv4("192.168.253.1/24")

    private func backups(in dir: FilePath) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.string)
            .filter { $0.hasPrefix("config.toml.bak-") }
    }

    @Test func appendsNetworkTableWhenMissing() {
        let out = NetworkConfigEditor.settingSubnet(new, in: "[build]\ncpus = 2\n")
        #expect(out.hasPrefix("[build]\ncpus = 2\n"))
        #expect(out.contains("[network]\nsubnet = \"192.168.253.1/24\""))
    }

    @Test func replacesExistingSubnet() {
        let out = NetworkConfigEditor.settingSubnet(new, in: "[network]\nsubnet = \"192.168.64.1/24\"\n")
        let subnetLines = out.split(separator: "\n").filter { $0.hasPrefix("subnet") }
        #expect(subnetLines == ["subnet = \"192.168.253.1/24\""])
    }

    @Test func insertsIntoExistingNetworkTable() {
        let input = "[network]\n# keep me\n[network.extra]\nsubnet = \"10.0.0.1/24\"\n"
        let out = NetworkConfigEditor.settingSubnet(new, in: input)
        #expect(out == "[network]\nsubnet = \"192.168.253.1/24\"\n# keep me\n[network.extra]\nsubnet = \"10.0.0.1/24\"\n")
    }

    @Test func preservesOtherSectionsAndComments() {
        let input = """
            # top comment
            [kernel]
            binaryPath = "a/b"

            [network]
            # my network
            subnet = "192.168.64.1/24"   # old
            subnetv6 = "fd00::/64"

            [registry]
            domain = "docker.io"

            """
        let out = NetworkConfigEditor.settingSubnet(new, in: input)
        let inLines = input.components(separatedBy: "\n")
        let outLines = out.components(separatedBy: "\n")
        #expect(inLines.count == outLines.count)
        for (a, b) in zip(inLines, outLines) where !a.hasPrefix("subnet =") {
            #expect(a == b)
        }
        #expect(outLines.contains("subnet = \"192.168.253.1/24\""))
    }

    @Test func readsSubnet() throws {
        #expect(NetworkConfigEditor.subnet(in: "[network]\nsubnet = \"192.168.253.1/24\"\n") == new)
        #expect(NetworkConfigEditor.subnet(in: "[build]\ncpus = 2\n") == nil)
        #expect(NetworkConfigEditor.subnet(in: "[network.extra]\nsubnet = \"192.168.253.1/24\"\n") == nil)
    }

    @Test func writeCreatesDirAndBacksUp() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let file = tempDir.appending("nested/container/config.toml")
            let first = try NetworkConfigEditor.write(subnet: try CIDRv4("192.168.64.1/24"), to: file, now: Date(timeIntervalSince1970: 1000))
            #expect(first == nil)
            let firstContent = try String(contentsOfFile: file.string, encoding: .utf8)

            let backup = try NetworkConfigEditor.write(subnet: new, to: file, now: Date(timeIntervalSince1970: 2000))
            let backupPath = try #require(backup)
            #expect(try String(contentsOfFile: backupPath.string, encoding: .utf8) == firstContent)
            #expect(NetworkConfigEditor.subnet(in: try String(contentsOfFile: file.string, encoding: .utf8)) == new)
        }
    }

    @Test func restoreRevertsFile() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let file = tempDir.appending("config.toml")
            try "[build]\ncpus = 2\n".write(toFile: file.string, atomically: true, encoding: .utf8)
            let backup = try #require(try NetworkConfigEditor.write(subnet: new, to: file))
            try NetworkConfigEditor.restore(backup: backup, to: file)
            #expect(try String(contentsOfFile: file.string, encoding: .utf8) == "[build]\ncpus = 2\n")
        }
    }

    @Test func keepsFiveBackups() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let file = tempDir.appending("config.toml")
            for i in 0..<7 {
                try NetworkConfigEditor.write(subnet: new, to: file, now: Date(timeIntervalSince1970: Double(1000 + i * 60)))
            }
            #expect(try backups(in: tempDir).count == 5)
        }
    }

    @Test func checkOnStartDefaultsTrue() async throws {
        try await TemporaryStorage.withTempDir { tempDir in
            let file = tempDir.appending("a.toml")
            try "[network]\n".write(toFile: file.string, atomically: true, encoding: .utf8)
            let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [file])
            #expect(config.network.shouldCheckOnStart == true)

            try "[network]\ncheckOnStart = false\n".write(toFile: file.string, atomically: true, encoding: .utf8)
            let off: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [file])
            #expect(off.network.shouldCheckOnStart == false)
        }
    }
    @Test func recognisesHeaderWithCommentAndSpaces() {
        let commented = NetworkConfigEditor.settingSubnet(new, in: "[network] # vm range\nsubnet = \"192.168.64.1/24\"\n")
        #expect(commented == "[network] # vm range\nsubnet = \"192.168.253.1/24\"\n")
        let spaced = NetworkConfigEditor.settingSubnet(new, in: "[ network ]\n")
        #expect(spaced == "[ network ]\nsubnet = \"192.168.253.1/24\"\n")
        #expect(NetworkConfigEditor.subnet(in: "[network] # c\nsubnet = \"192.168.253.1/24\"\n") == new)
    }

    @Test func handlesCRLF() {
        let out = NetworkConfigEditor.settingSubnet(new, in: "[network]\r\nsubnet = \"192.168.64.1/24\"\r\n")
        #expect(!out.contains("\n[network]\n"))
        #expect(NetworkConfigEditor.subnet(in: out) == new)
        #expect(out.components(separatedBy: "[network]").count == 2)
    }

    @Test func refusesEditThatWouldBreakTOML() throws {
        let original = "network.subnet = \"192.168.64.1/24\"\n"
        try withTempFile(original) { file in
            var threw = false
            do {
                try NetworkConfigEditor.write(subnet: new, to: file)
            } catch {
                threw = true
            }
            #expect(threw)
            let after = try String(contentsOfFile: file.string, encoding: .utf8)
            #expect(after == original)
        }
    }

    private func withTempFile(_ contents: String, _ body: (FilePath) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FilePath(dir.path).appending("config.toml")
        try contents.write(toFile: file.string, atomically: true, encoding: .utf8)
        try body(file)
    }
}
