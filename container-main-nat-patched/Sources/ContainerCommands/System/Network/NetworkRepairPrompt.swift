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
import Darwin
import Foundation

public enum RepairChoice: Equatable, Sendable {
    case repairNow
    case updateOnly
    case doNothing
}

/// Terminal access for the repair prompt, injectable for tests.
public struct PromptIO: Sendable {
    public var isTTY: @Sendable () -> Bool
    public var readLine: @Sendable () -> String?
    public var write: @Sendable (String) -> Void

    public init(
        isTTY: @escaping @Sendable () -> Bool,
        readLine: @escaping @Sendable () -> String?,
        write: @escaping @Sendable (String) -> Void
    ) {
        self.isTTY = isTTY
        self.readLine = readLine
        self.write = write
    }

    public static let standard = PromptIO(
        isTTY: { isatty(STDIN_FILENO) == 1 },
        readLine: { readLinePausingForwarding() },
        write: { FileHandle.standardError.write(Data($0.utf8)) }
    )

    /// Reads a line from stdin even when an interactive session's `ProcessIO` is already
    /// forwarding stdin to the container: pauses the forwarding handler and non-blocking
    /// mode for the duration of the read, then restores both.
    private static func readLinePausingForwarding() -> String? {
        let stdinHandle = FileHandle.standardInput
        let forwarder = stdinHandle.readabilityHandler
        stdinHandle.readabilityHandler = nil
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        if flags >= 0 && flags & O_NONBLOCK != 0 {
            _ = fcntl(STDIN_FILENO, F_SETFL, flags & ~O_NONBLOCK)
        }
        defer {
            if flags >= 0 {
                _ = fcntl(STDIN_FILENO, F_SETFL, flags)
            }
            stdinHandle.readabilityHandler = forwarder
        }
        clearerr(Darwin.stdin)
        return Swift.readLine()
    }
}

public struct RunningContainerInfo: Sendable, Equatable {
    public let id: String
    /// Whether the container's init process has a terminal.
    public let interactive: Bool

    public init(id: String, interactive: Bool) {
        self.id = id
        self.interactive = interactive
    }
}

/// The text and choices shown when a container's network gateway is missing.
public enum NetworkRepairPrompt {
    private static let maxAttempts = 3

    public static func notification(
        containerId: String,
        diagnosis: NetworkDiagnosis,
        running: [RunningContainerInfo],
        recent: NetworkRepairRecord?
    ) -> String {
        var lines = ["⚠ Network problem: \(containerId) has no network access."]
        switch diagnosis {
        case .mismatch(let current, let suggested, _):
            lines.append("  container is using \(range(current)), but your Mac's VM network is \(range(suggested))")
        case .ambiguous(let current, let candidates):
            let ranges = candidates.map { range($0.cidr) }.joined(separator: " or ")
            lines.append("  container is using \(range(current)), but your Mac's VM network looks like \(ranges)")
        case .ok, .undetermined:
            break
        }
        lines.append("  (probably changed by another app such as Multipass).")

        if let recent {
            let minutes = max(1, Int(Date().timeIntervalSince(recent.date) / 60))
            lines.append("")
            lines.append(
                "  Note: this was changed to \(recent.to) \(minutes) minutes ago, so another app may be switching it back and forth."
            )
        }

        lines.append("")
        lines.append("  Repairing updates container's settings and restarts container services.")
        return lines.joined(separator: "\n") + "\n" + restartWarning(running: running)
            + "\nRun 'container system network check' for details.\n"
    }

    /// Which containers a services restart will interrupt.
    public static func restartWarning(running: [RunningContainerInfo]) -> String {
        var lines: [String] = []
        if !running.isEmpty {
            lines.append("  These running containers will be restarted:")
            for container in running {
                let suffix = container.interactive ? " (interactive session will be disconnected)" : ""
                lines.append("    \(container.id)\(suffix)")
            }
        }
        lines.append("  Containers started with --rm will be removed rather than restarted.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Asks which candidate network to use. Returns nil without a TTY, or when the user doesn't know.
    public static func chooseNetwork(_ candidates: [HostInterface], io: PromptIO) -> CIDRv4? {
        guard io.isTTY() else {
            return nil
        }
        var text = "\nWhich network is your Mac using for VMs?\n"
        for (index, candidate) in candidates.enumerated() {
            text += "  [\(index + 1)] \(candidate.name) \(candidate.cidr)\n"
        }
        let unknown = candidates.count + 1
        text += "  [\(unknown)] I don't know, show me how to check\n> "
        io.write(text)

        guard let answer = io.readLine()?.trimmingCharacters(in: .whitespaces),
            let index = Int(answer), (1...candidates.count).contains(index)
        else {
            return nil
        }
        return candidates[index - 1].cidr
    }

    /// Asks what to do. Returns nil without a TTY; Enter, end of input, or repeated
    /// invalid answers mean `.doNothing`.
    public static func chooseAction(io: PromptIO) -> RepairChoice? {
        guard io.isTTY() else {
            return nil
        }
        io.write(
            """

              [1] Repair automatically now
              [2] Update the setting only. I'll restart later
              [3] Do nothing

            """)
        for _ in 0..<maxAttempts {
            io.write("Choose 1, 2 or 3 [3]: ")
            guard let answer = io.readLine()?.trimmingCharacters(in: .whitespaces) else {
                return .doNothing
            }
            switch answer {
            case "1": return .repairNow
            case "2": return .updateOnly
            case "", "3": return .doNothing
            default: continue
            }
        }
        return .doNothing
    }

    /// The commands to fix it by hand.
    public static func manualSteps(suggested: CIDRv4?, containerIds: [String]) -> String {
        var lines = ["To fix this yourself:"]
        if let suggested {
            lines.append("  1. Add this to ~/.config/container/config.toml:")
            lines.append("       [network]")
            lines.append("       subnet = \"\(suggested)\"")
        } else {
            lines.append("  1. Find your Mac's VM network:")
            lines.append("       container system network check --admin")
            lines.append("     then add it to ~/.config/container/config.toml under [network] as subnet = \"<address>/24\"")
        }
        lines.append("  2. Restart:")
        lines.append("       container system stop && container system start")
        for id in containerIds {
            lines.append("       container start \(id)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `192.168.253.1/24` → `192.168.253.x`.
    static func range(_ cidr: CIDRv4) -> String {
        let octets = cidr.address.description.split(separator: ".").prefix(3)
        return octets.joined(separator: ".") + ".x"
    }
}
