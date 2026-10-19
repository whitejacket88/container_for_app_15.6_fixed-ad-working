# macOS 15 Network Range Auto-Detect and Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS 15, detect when a container's network gateway doesn't exist on the Mac
because another app moved the Mac's shared VM range. Tell the user plainly, and let them choose:
repair automatically, update the setting only, or do nothing.

**Architecture:**
- A pure `NetworkDiagnosis.diagnose` function decides `.ok`, `.mismatch`, `.ambiguous` or
  `.undetermined` from the configured gateway and the Mac's interfaces.
- Thin adapters feed it: `getifaddrs`, and an optional `sudo defaults read`.
- A prompt component renders the notification and parses the choice.
- A repairer edits `~/.config/container/config.toml` (with backups), restarts services through
  the CLI's own `system stop/start`, restarts containers, verifies, and rolls back on failure.
- The flow is called from `container start`, `container run` and a new
  `container system network check`.

**Tech Stack:** Swift 6, swift-argument-parser, Swift Testing (`import Testing`, `@Test`,
`#expect`), `ContainerizationExtras` (`CIDRv4`, `IPv4Address`), Darwin `getifaddrs`.

**Spec:** `docs/superpowers/specs/2026-10-18-macos15-network-autodetect-design.md`. Read it
first. Section numbers below refer to it.

**Working directory for every command:**
`/Users/whitejacket88/Workspace/App.Projects/FieldTECh.app.local/workspace/container/container-main-nat-patched`

## Global Constraints

- **macOS 15 only.** Every behavior runs only when the container's attachment
  `variant == "allocationOnly"`. On macOS 26, `network check` prints "managed automatically by
  macOS 26" and exits 0.
- **Never** modify `/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist` or other VM
  tools. Only read it, and only under `--admin`.
- **No password** in the start/run path. `sudo` is used only by `container system network check --admin`.
- **Nothing changes without the user choosing [1] or [2].** Pressing Enter means [3] Do nothing.
- **Without a TTY on stdin:** print the notification and the manual commands, change nothing,
  never block on input.
- **Gateway rule:** gateway = `subnet.lower + 1` (matches `AllocationOnlyVmnetNetwork.start()`).
- **Default subnet:** `192.168.64.1/24`.
- **User config path:** `ConfigurationLoader.configurationFile(.home)`, which is
  `~/.config/container/config.toml` and respects `XDG_CONFIG_HOME`.
- **Backups:** `config.toml.bak-<ISO8601>` next to it. Keep the newest 5.
- **History file:** `<appRoot>/network-repair.json`. The "recently changed" window is 600 seconds.
- **Opt-out key:** `[network] checkOnStart = false`. It defaults to true.
- **Choice labels, verbatim:**
  - `[1] Repair automatically now`
  - `[2] Update the setting only. I'll restart later`
  - `[3] Do nothing`
- **`network check` exit codes:** `0` ok, `1` mismatch unfixed, `2` ambiguous or undetermined,
  `3` error.
- **License header:** new files start with the same Apache header block as existing files
  (copy from any `Sources/**/*.swift`).
- **Commits:** the user has not asked for commits. At each "Checkpoint" step, run the listed
  tests only. Commit only if the user says so.

## Review Focus

1. **Config file with other sections and comments**, e.g. the user's `[build]`/`[kernel]`
   settings and `#` comments. The edit must change only `[network].subnet`. *(Task 2 test
   `preservesOtherSectionsAndComments`.)*
2. **`[network]` exists but has no `subnet`, or `subnet` sits inside a different table.**
   Insert the key into `[network]`, and never into `[network.something]` or another section.
   *(Task 2 test `insertsIntoExistingNetworkTable`.)*
3. **Several bridges where neither matches**, which is the author's exact Mac
   (`192.168.252.1` Multipass plus `192.168.253.1`). This must be `.ambiguous`, never a guess.
   *(Task 1 test `twoBridgesNoSignalIsAmbiguous`.)*
4. **Stdin is not a TTY**, e.g. `container start x < /dev/null` or under launchd. The flow must
   not call `readLine` and must not change files. *(Task 4 test `nonTTYNeverReadsOrWrites`.)*
5. **Interactive `run -it` whose terminal is already in raw mode** when the prompt appears. The
   prompt must reset the terminal first and restore raw mode afterwards. *(Task 6 manual step
   plus the `console` hand-off in Task 6 Step 3.)*

---

### Task 1: Diagnosis core

**Files:**
- Create: `Sources/ContainerCommands/System/Network/NetworkDiagnosis.swift`
- Test: `Tests/ContainerCommandsTests/NetworkDiagnosisTests.swift`
- Modify (only if `import ContainerizationExtras` fails to resolve): `Package.swift`. Add
  `.product(name: "ContainerizationExtras", package: "containerization")` to the
  `ContainerCommands` target and the `ContainerCommandsTests` target.

**Interfaces (produces):**

```swift
public struct HostInterface: Sendable, Equatable {
    public let name: String          // e.g. "bridge101"
    public let address: IPv4Address
    public let prefixLength: UInt8   // from netmask
    public var cidr: CIDRv4 { get }   // network of address/prefixLength, rendered as "<gateway>/<len>" like config: "192.168.253.1/24"
}

public enum NetworkDiagnosis: Sendable, Equatable {
    case ok
    case mismatch(current: CIDRv4, suggested: CIDRv4, evidence: String)
    case ambiguous(current: CIDRv4, candidates: [HostInterface])
    case undetermined(current: CIDRv4)

    public static func diagnose(
        configuredSubnet: CIDRv4,
        hostInterfaces: [HostInterface],
        systemSharedAddress: IPv4Address?,   // rule 1, from --admin only
        containerBridge: String?            // rule 2, bridge name if known; nil until Task 9
    ) -> NetworkDiagnosis

    public static func gateway(of subnet: CIDRv4) -> IPv4Address   // subnet.lower + 1
}
```

Candidate filter: only interfaces whose name has the prefix `bridge` and whose address is in
`192.168.0.0/16`, `172.16.0.0/12` or `10.0.0.0/8`.

`.ok` requires that some interface holds `gateway(of: configuredSubnet)`. **And:** if
`systemSharedAddress` is non-nil, it must equal that gateway. If `containerBridge` is non-nil,
the interface holding the gateway must be that bridge.

The suggestion is built as a CIDR of the winning interface address with its prefix length, e.g.
`192.168.253.1/24`.

- [ ] **Step 1: Write the failing tests** in `NetworkDiagnosisTests` (Swift Testing). `b(name, ip)` is a local helper building a `/24` `HostInterface`.
  - `okWhenGatewayPresent`: configured `192.168.64.1/24` with `[b("bridge100","192.168.64.1")]` → `#expect(result == .ok)`.
  - `mismatchSingleBridge`: configured `192.168.64.1/24` with `[b("bridge101","192.168.253.1"), b("en0","192.168.1.20")]` → `.mismatch` with `suggested == CIDRv4("192.168.253.1/24")`. `en0` is ignored because it isn't a bridge.
  - `twoBridgesNoSignalIsAmbiguous`: configured `192.168.64.1/24` with `[b("bridge100","192.168.252.1"), b("bridge101","192.168.253.1")]` → `.ambiguous` with both candidates.
  - `systemAddressWins`: same two bridges plus `systemSharedAddress: "192.168.253.1"` → `.mismatch(suggested: 192.168.253.1/24)`.
  - `containerBridgeWins`: same two bridges plus `containerBridge: "bridge100"` → `.mismatch(suggested: 192.168.252.1/24)`.
  - `okRejectedWhenSystemAddressDisagrees`: configured `192.168.252.1/24`, both bridges present, `systemSharedAddress: "192.168.253.1"` → `.mismatch(suggested: 192.168.253.1/24)`, not `.ok`.
  - `noBridgesIsUndetermined`: configured `192.168.64.1/24`, `[b("en0","10.0.0.5")]` → `.undetermined`.
  - `gatewayIsLowerPlusOne`: `gateway(of: CIDRv4("192.168.253.0/24"))` and `gateway(of: CIDRv4("192.168.253.1/24"))` both equal `192.168.253.1`.

- [ ] **Step 2: Run them and confirm they fail**

  Run: `swift test --filter NetworkDiagnosisTests`

  Expected: build error, because `NetworkDiagnosis` is undefined.

- [ ] **Step 3: Implement `HostInterface` and `NetworkDiagnosis.diagnose`** in `NetworkDiagnosis.swift`. Apply the rule order from spec Section 1: system address, then container bridge, then single RFC1918 bridge, then ambiguous.

- [ ] **Step 4: Run them and confirm they pass**

  Run: `swift test --filter NetworkDiagnosisTests`

  Expected: all 8 pass.

- [ ] **Step 5: Checkpoint.** Run `swift test --filter ContainerCommandsTests` and confirm the existing tests still pass.

---

### Task 2: Config editor with backups, and the `checkOnStart` key

**Files:**
- Create: `Sources/ContainerPersistence/NetworkConfigEditor.swift`
- Modify: `Sources/ContainerPersistence/ContainerSystemConfig.swift:231-239`. Add
  `public let checkOnStart: Bool?` to `NetworkConfig`, add an init parameter defaulting to `nil`,
  and add `public var shouldCheckOnStart: Bool { checkOnStart ?? true }`.
- Test: `Tests/ContainerPersistenceTests/NetworkConfigEditorTests.swift`

**Interfaces (produces):**

```swift
public enum NetworkConfigEditor {
    /// Returns new file text with [network].subnet set; everything else byte-identical.
    public static func settingSubnet(_ subnet: CIDRv4, in text: String) -> String
    /// Reads [network].subnet from text, nil if absent.
    public static func subnet(in text: String) -> CIDRv4?
    /// Backs up (if file exists), then writes. Creates parent dir. Returns backup path or nil.
    @discardableResult
    public static func write(subnet: CIDRv4, to file: FilePath, now: Date = Date(), keepBackups: Int = 5) throws -> FilePath?
    /// Restores a backup over `file`.
    public static func restore(backup: FilePath, to file: FilePath) throws
}
```

Line-based edit:
- Find the `[network]` table header line. Match exactly `[network]` after trimming, so
  `[network.x]` does not count.
- Within that table, up to the next line starting with `[`, replace the
  `subnet = ...` line, or insert `subnet = "<cidr>"` directly after the header.
- If there is no `[network]` table, append `\n[network]\nsubnet = "<cidr>"\n`.

The backup name uses `ISO8601DateFormatter` with `:` replaced by `-`. When pruning, sort the
`config.toml.bak-*` files by name and delete all but the newest `keepBackups`.

- [ ] **Step 1: Write the failing tests**
  - `appendsNetworkTableWhenMissing`: `"[build]\ncpus = 2\n"` produces text containing `"[network]\nsubnet = \"192.168.253.1/24\""`, and `[build]` is unchanged.
  - `replacesExistingSubnet`: `"[network]\nsubnet = \"192.168.64.1/24\"\n"` produces exactly one `subnet =` line, with the new value.
  - `insertsIntoExistingNetworkTable`: `"[network]\n# keep me\n[network.extra]\nsubnet = \"10.0.0.1/24\"\n"` puts the new subnet under `[network]`, and the `[network.extra]` value stays `10.0.0.1/24`.
  - `preservesOtherSectionsAndComments`: input with `# top comment`, `[kernel]` keys and `[network]` with a comment line. Every line except the `subnet` line is identical.
  - `readsSubnet`: `subnet(in:)` returns `192.168.253.1/24` from a valid file and `nil` from a file without `[network]`.
  - `writeCreatesDirAndBacksUp`: write into a temp dir, twice, with different `now`. The second call returns a backup path whose content equals the first write.
  - `keepsFiveBackups`: 7 writes produce 5 `config.toml.bak-*` files.
  - `checkOnStartDefaultsTrue`: a `ContainerSystemConfig` decoded from `"[network]\n"` has `network.shouldCheckOnStart == true`, and one decoded from `checkOnStart = false` has it `false`. Copy the decoding approach from the existing `ConfigurationLoaderTests`.

- [ ] **Step 2: Run them and confirm they fail.** Run `swift test --filter NetworkConfigEditorTests` and expect a build error.

- [ ] **Step 3: Implement** `NetworkConfigEditor` and the `checkOnStart` field.

- [ ] **Step 4: Run them and confirm they pass.** Run `swift test --filter NetworkConfigEditorTests` and expect all 8 to pass. Then run `swift test --filter ContainerPersistenceTests` and expect no regressions.

- [ ] **Step 5: Checkpoint.**

---

### Task 3: Host adapters (interfaces, and the admin system-address read)

**Files:**
- Create: `Sources/ContainerCommands/System/Network/HostNetworkProbe.swift`
- Test: `Tests/ContainerCommandsTests/HostNetworkProbeTests.swift`

**Interfaces (produces):**

```swift
public enum HostNetworkProbe {
    /// All IPv4 interfaces via getifaddrs (pattern: Sources/ContainerOS/LocalNetworkPrivacy.swift:91-107).
    public static func ipv4Interfaces() -> [HostInterface]
    /// Parses `defaults read` output for Shared_Net_Address; nil if absent/garbled.
    public static func parseSharedAddress(_ defaultsOutput: String) -> IPv4Address?
    /// Runs `/usr/bin/sudo /usr/bin/defaults read /Library/Preferences/SystemConfiguration/com.apple.vmnet Shared_Net_Address`
    /// with inherited stdio for the password prompt. Throws on non-zero exit.
    public static func readSystemSharedAddress() throws -> IPv4Address?
}
```

The prefix length comes from `ifa_netmask`, as the popcount of the mask.

- [ ] **Step 1: Write the failing tests**
  - `parsesSharedAddress`: `parseSharedAddress("192.168.253.1\n") == IPv4Address("192.168.253.1")`.
  - `parseRejectsGarbage`: `"The domain/default pair ... does not exist"` returns `nil`.
  - `enumeratesLoopback`: `ipv4Interfaces()` contains a `lo0` entry with `127.0.0.1` and `prefixLength == 8`.
- [ ] **Step 2: Run `swift test --filter HostNetworkProbeTests`** and expect them to fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run again** and expect 3 passes.
- [ ] **Step 5: Checkpoint.**

---

### Task 4: Repair history, notification text and the choice prompt

**Files:**
- Create: `Sources/ContainerCommands/System/Network/NetworkRepairHistory.swift`
- Create: `Sources/ContainerCommands/System/Network/NetworkRepairPrompt.swift`
- Test: `Tests/ContainerCommandsTests/NetworkRepairPromptTests.swift`

**Interfaces (produces):**

```swift
public struct NetworkRepairRecord: Codable, Sendable, Equatable {
    public let date: Date
    public let from: String      // CIDR text
    public let to: String
    public let choice: Int       // 1 or 2
    public var pending: Bool      // true after [2] until a later check sees the running net == `to`
}
public struct NetworkRepairHistory: Sendable {
    public init(file: FilePath)   // production: <appRoot>/network-repair.json
    public func load() -> [NetworkRepairRecord]          // [] if missing or unreadable
    public func append(_ r: NetworkRepairRecord) throws  // keep newest 20
    public func markApplied(to: String) throws           // clear pending on matching records
    /// Record that set the range to `cidr` within `window` seconds of `now`, if any.
    public func recentChange(to cidr: String, now: Date, window: TimeInterval = 600) -> NetworkRepairRecord?
}

public enum RepairChoice: Equatable, Sendable { case repairNow, updateOnly, doNothing }

public struct PromptIO: Sendable {
    public var isTTY: @Sendable () -> Bool
    public var readLine: @Sendable () -> String?
    public var write: @Sendable (String) -> Void
    public static let standard: PromptIO   // isatty(STDIN_FILENO), Swift.readLine(), FileHandle.standardError
}

public struct RunningContainerInfo: Sendable, Equatable {
    public let id: String
    public let interactive: Bool   // configuration.initProcess.terminal
}

public enum NetworkRepairPrompt {
    public static func notification(containerId: String, diagnosis: NetworkDiagnosis,
                                    running: [RunningContainerInfo], recent: NetworkRepairRecord?) -> String
    /// Returns nil when not a TTY (caller prints manualSteps and changes nothing).
    public static func chooseNetwork(_ candidates: [HostInterface], io: PromptIO) -> CIDRv4?
    public static func chooseAction(io: PromptIO) -> RepairChoice?   // nil when not TTY
    public static func manualSteps(suggested: CIDRv4?, containerIds: [String]) -> String
}
```

Copy rules (spec Section 2.3):
- **Notification:** the first line is `⚠ Network problem: <id> has no network access.` The
  second names both ranges as `x.y.z.x` (the first three octets, then `.x`) and adds
  "(probably changed by another app such as Multipass)".
- **Restart list:** every running container. An interactive one gets the suffix
  ` (interactive session will be disconnected)`. Then the line
  `Containers started with --rm will be removed rather than restarted.` The client cannot see
  `autoRemove` for other containers, so it is stated generally; this is a deviation from the
  spec, so record it in the PR notes.
- **Recent change:** if `recent != nil`, add
  `Note: this was changed to <to> <n> minutes ago, so another app may be switching it back and forth.`
- Every notification ends with `Run 'container system network check' for details.`
- **`chooseNetwork`:** lists `[n] <iface> <cidr>` plus a final `[k] I don't know, show me how to check`. Choosing `[k]`, an empty line or invalid input returns `nil`.
- **`chooseAction`:** prints the three labels from Global Constraints. Empty input or `3` means
  `.doNothing`. Invalid input re-asks at most twice, then returns `.doNothing`.
- **`manualSteps`:** prints the config snippet, then
  `container system stop && container system start`, then `container start <id>` for each id.

- [ ] **Step 1: Write the failing tests**, using a fake `PromptIO` that records writes and serves scripted lines.
  - `nonTTYNeverReadsOrWrites`: with `isTTY = false`, `chooseAction` and `chooseNetwork` return `nil`, and `readLine` is never called. The fake should `Issue.record` if it is.
  - `enterMeansDoNothing`: input `""` returns `.doNothing`.
  - `choiceOneAndTwo`: `"1"` returns `.repairNow`, and `"2"` returns `.updateOnly`.
  - `invalidThenGiveUp`: `"x","y","z"` returns `.doNothing`, with exactly 3 reads.
  - `chooseNetworkPicksSecond`: two candidates, input `"2"`, returns the second's CIDR. Input `"3"` (the "don't know" option) returns `nil`.
  - `notificationListsAllRunning`: running `[kali-gui(interactive), web]`. The text contains `kali-gui (interactive session will be disconnected)`, `web` and `--rm`.
  - `notificationMentionsRecentChange`: with a record 3 minutes old, the text contains `3 minutes ago`.
  - `historyRecentWindow`: a record at `now-300` is found, and one at `now-700` is not.
  - `historyMarkApplied`: append pending to `192.168.253.1/24`, then `markApplied`, then `load()[0].pending == false`.
- [ ] **Step 2: Run `swift test --filter NetworkRepairPromptTests`** and expect them to fail.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run again** and expect 9 passes.
- [ ] **Step 5: Checkpoint.**

---

### Task 5: Repairer (apply, verify, roll back) and the shared flow

**Files:**
- Create: `Sources/ContainerCommands/System/Network/NetworkRepairer.swift`
- Create: `Sources/ContainerCommands/System/Network/NetworkStartCheck.swift`
- Test: `Tests/ContainerCommandsTests/NetworkRepairerTests.swift`

**Interfaces:**
- **Consumes:** Tasks 1–4.
- **Produces:**

```swift
/// Side effects the repairer needs; production impl shells out to the running CLI binary
/// (CommandLine.arguments[0]) so behaviour matches `container system stop/start` exactly.
public protocol ContainerSystemControl: Sendable {
    func stopSystem() async throws                 // `container system stop`
    func startSystem() async throws                // `container system start --disable-kernel-install`
    func startContainer(id: String) async throws   // `container start <id>` (detached)
    func exists(id: String) async -> Bool
    func runningGateway(of id: String) async throws -> IPv4Address?   // from ContainerClient().get(id:).networks.first
    func hostInterfaces() -> [HostInterface]
}

public enum RepairOutcome: Equatable, Sendable {
    case repaired(restarted: [String], removed: [String], stoppedInteractive: [String])
    case updatedOnly(backup: FilePath?)
    case rolledBack(reason: String)
}

public struct NetworkRepairer: Sendable {
    public init(control: any ContainerSystemControl, configFile: FilePath, history: NetworkRepairHistory)
    public func updateOnly(from: CIDRv4, to: CIDRv4) throws -> RepairOutcome
    public func repairNow(from: CIDRv4, to: CIDRv4, running: [RunningContainerInfo], verifyId: String) async -> RepairOutcome
}

public enum StartCheckResult: Equatable, Sendable {
    case proceed                 // ok, opted out, not macOS 15, or user chose 2/3
    case restartedNeedsRebootstrap // user chose 1 and repair succeeded: caller must bootstrap again
}

public enum NetworkStartCheck {
    public static func run(containerId: String, client: ContainerClient, config: ContainerSystemConfig,
                           console: Terminal?, io: PromptIO = .standard,
                           control: any ContainerSystemControl = CLISystemControl()) async -> StartCheckResult
}
public struct CLISystemControl: ContainerSystemControl { public init() }
```

`repairNow` sequence (spec Section 4):
1. Write the config with a backup (Task 2).
2. Append a history record with `pending: true`.
3. `stopSystem`, then `startSystem`.
4. For each `running` entry that isn't interactive: if `exists`, run `startContainer`; if not,
   add it to `removed`.
5. Interactive entries go into `stoppedInteractive` and are not restarted. They print
   `container start -ai <id>`.
6. Verify: start `verifyId` if it isn't already running, then
   `runningGateway(of: verifyId)` must be held by some `hostInterfaces()` entry.
7. On success, `markApplied`.
8. On any thrown error or failed verify: `restore(backup)`, `stopSystem`, `startSystem`, then
   return `.rolledBack(reason:)`.

`updateOnly`: write the config with a backup, append a pending record, return `.updatedOnly`.

`NetworkStartCheck.run` returns `.proceed` immediately when any of these holds:
- `!config.network.shouldCheckOnStart`;
- the attachment `variant != "allocationOnly"`;
- the attachment is missing.

Otherwise:
1. Diagnose with `containerBridge: nil` and `systemSharedAddress: nil`.
2. **Pending state:** if the user config's `subnet(in:)` already equals the suggestion (or, for
   `.ambiguous`, any candidate), write the "already updated; restart to apply" message, then
   offer only `[1]` (repair now = restart) or `[3]`.
3. If `console != nil`, call `console.reset()` before prompting and `console.setraw()`
   afterwards.
4. **Non-TTY:** write the notification and `manualSteps`, then return `.proceed`.
5. **`.undetermined`:** write
   `⚠ container may have no network; run 'container system network check --admin'.` and return
   `.proceed`.
6. Log every outcome with the caller's `Logger` at info level.

- [ ] **Step 1: Write the failing tests** with a `FakeControl` (an actor recording calls, configurable failures and gateway) and a temp `configFile`.
  - `updateOnlyWritesAndRecordsPending`: the config contains the new subnet, the history has one pending record, and `FakeControl` saw no stop/start.
  - `repairNowHappyPath`: running `[a(non-int), b(interactive)]`. The calls are `stop`, `start`, `startContainer(a)`, then verify. The outcome is `.repaired(restarted:["a"], removed:[], stoppedInteractive:["b"])` and the history is no longer pending.
  - `repairNowReportsRemoved`: `exists("a") == false` puts `a` in `removed`.
  - `repairNowRollsBackOnVerifyFailure`: the gateway is not among the host interfaces. The result is `.rolledBack`, the config content equals its original bytes, and stop/start was called twice.
  - `repairNowRollsBackOnStartFailure`: `startSystem` throws the first time. The result is `.rolledBack` and the config is restored.
- [ ] **Step 2: Run `swift test --filter NetworkRepairerTests`** and expect them to fail.
- [ ] **Step 3: Implement** `NetworkRepairer`, `CLISystemControl` (`Process` with `executableURL` = resolved `CommandLine.arguments[0]`, inherited stdout/stderr, throws on non-zero exit) and `NetworkStartCheck`.
- [ ] **Step 4: Run again** and expect 5 passes. Then run `swift test --filter ContainerCommandsTests`.
- [ ] **Step 5: Checkpoint.**

---

### Task 6: Hook into `container start` and `container run`

**Files:**
- Modify: `Sources/ContainerCommands/Container/ContainerStart.swift:93-110`
- Modify: `Sources/ContainerCommands/Container/ContainerRun.swift:137-170`

Insertion point in both files: immediately after `let process = try await client.bootstrap(...)`
and `progress.finish()`, and before `process.start()` or `io.handleProcess`. Call:

```swift
let check = await NetworkStartCheck.run(containerId: <id>, client: client,
                                        config: try await ClientHealthCheck.loadContainerSystemConfig(),
                                        console: io.console)
```

Note that `ContainerRun` already has `containerSystemConfig`, so reuse it there.

On `.restartedNeedsRebootstrap`:
- **`ContainerStart`:** close `io`, then re-run the same start logic once for the same id. Do
  this by extracting the body after the `status == .running` guard into
  `private func startOnce(client:allowNetworkCheck:) async throws -> Int32`, and call it again
  with `allowNetworkCheck: false`.
- **`ContainerRun`:** if `client.get(id:)` still finds the container, do the same with an
  equivalent extracted helper. Otherwise (`--rm` deleted it), print
  `The container was removed by the restart. Run the same command again.` and exit 1.

- [ ] **Step 1: Implement the hooks and the `startOnce` refactors.** No behavior change when the check returns `.proceed`.
- [ ] **Step 2: Build and run the full unit suite.** Run `make BUILD_CONFIGURATION=debug test` and expect a pass count ≥ the previous 956 plus the new tests, with 0 failures.
- [ ] **Step 3: Install and test manually on this Mac** (spec "Testing" acceptance). Build and install as described in `../REPAIR_README.md`, then:
  1. Back up `~/.config/container/config.toml`, then delete its `[network]` lines.
  2. Run `container system stop && container system start`.
  3. Run `container start kali-gui`. Expect the notification. If both Multipass and shared bridges exist, expect the "which network?" list first.
  4. Choose `[1]`. Expect `container exec kali-gui getent hosts http.kali.org` to resolve, and a backup file to exist.
  5. Repeat steps 1–3 and choose `[2]`. Expect the config to be updated and restart commands printed, with nothing restarted.
  6. Repeat and choose `[3]` (or press Enter). Expect no change.
  7. Repeat with `container run -it --rm docker.io/kalilinux/kali-rolling bash`. Expect the prompt to be readable (not raw-mode garbled) before the shell, and the shell to work normally afterwards.
  8. Repeat with `container start kali-gui < /dev/null`. Expect the notification and commands, no prompt, and no change.
  9. Restore the original config.
- [ ] **Step 4: Checkpoint.**

---

### Task 7: `container system network check`

**Files:**
- Create: `Sources/ContainerCommands/System/SystemNetwork.swift`. This is the group command
  `network`, with abstract "Diagnose the default container network" and subcommands
  `[SystemNetworkCheck.self]`.
- Create: `Sources/ContainerCommands/System/Network/SystemNetworkCheck.swift`
- Modify: `Sources/ContainerCommands/System/SystemCommand.swift:27-37`. Add `SystemNetwork.self`
  to `subcommands`, keeping alphabetical order (after `SystemLogs`).
- Test: `Tests/ContainerCommandsTests/SystemNetworkCheckTests.swift`

**Interfaces:**

```swift
extension Application {
    public struct SystemNetworkCheck: AsyncLoggableCommand {
        // commandName: "check", abstract: "Check that containers can reach the network, and offer to fix it"
        @Flag var admin = false           // uses HostNetworkProbe.readSystemSharedAddress()
        @Flag var fix = false             // act as choice [1] without prompting
        @Option var subnet: String? = nil // CIDRv4 override, e.g. 192.168.253.1/24
        static func exitCode(for d: NetworkDiagnosis, fixed: Bool) -> Int32  // 0/1/2 per Global Constraints
    }
}
```

**Behavior:**
1. Print the configured subnet (from the running network status if services are up, else
   config) and its gateway.
2. List the `bridge*` interfaces, then the diagnosis verdict in one line.
3. For each running container on the default network, run the probe through
   `container exec <id> sh -c 'getent hosts http.kali.org >/dev/null && echo dns-ok'`, and
   print `reachable` or `no network`.
4. Then:
   - With a TTY, `--fix` absent and a problem found: run the same notification and choices as
     Task 5.
   - With `--fix`: choose [1]. If the result is `.ambiguous` and `--subnet` is absent, print the
     candidates and exit 2.
   - On macOS ≥ 26 (`#available(macOS 26, *)`): print
     `Networking is managed automatically by macOS 26 or later.` and exit 0.
5. On any thrown error, print it and exit 3.

- [ ] **Step 1: Write the failing tests:**
  - `exitCodes`: `.ok` gives 0, `.mismatch` unfixed gives 1, `.ambiguous` gives 2, `.undetermined` gives 2, and `.mismatch` fixed gives 0.
  - `helpListsFlags`: `Application.SystemNetworkCheck.helpMessage()` contains `--admin`, `--fix` and `--subnet`.
- [ ] **Step 2: Run `swift test --filter SystemNetworkCheckTests`** and expect them to fail.
- [ ] **Step 3: Implement** both commands and the registration.
- [ ] **Step 4: Run again** and expect 2 passes. Also check manually that `container system network check` and `container system network check --admin` show the bridge list and verdict on this Mac.
- [ ] **Step 5: Checkpoint.**

---

### Task 8: Docs and README

**Files:**
- Modify: `docs/networking.md`. Add `## macOS 15: when containers have no network` after
  `## Configure default network subnets` (line 256). Cover the cause, the prompt and its three
  choices, `checkOnStart = false`, `container system network check [--admin] [--fix] [--subnet]`,
  and the manual `config.toml` fix.
- Modify: `docs/command-reference.md`. Add `### \`container system network check\`` after the
  `container system logs` entry, in the same format as its neighbours (usage line, options
  list).
- Modify: `../REPAIR_README.md`.
  - Section 3: change "Permanent fix (designed, not yet implemented)" to describe the shipped
    behavior, and keep the manual workaround.
  - Folder layout table: `container-main-nat-patched` now "contains the networking fix".
  - Remove the sentence "The `Sources/` trees … are currently identical".
  - Build commands: point at `container-main-nat-patched`.
  - Verification block: add the new test count.

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run `make BUILD_CONFIGURATION=debug installer-pkg`** and expect `bin/debug/container-installer-unsigned.pkg` to be produced.
- [ ] **Step 3: Checkpoint.**

---

### Task 9 (optional, time-boxed to one session): Rule 2, bridge membership

This makes Macs like the author's resolve automatically instead of asking "which network?".
**Stop and skip it** if it isn't reliable. The user decided rule 2 is a nice-to-have.

**Files:**
- Modify: `Sources/ContainerCommands/System/Network/HostNetworkProbe.swift`. Add
  `public static func bridgeMembers() -> [String: [String]]` (bridge name → member interface
  names) using `ioctl(SIOCGDRVSPEC)` with `BRDGGIFS`, as `ifconfig bridgeN` does.
- Modify: `NetworkStartCheck.swift`. Find the container's bridge as follows: the member
  `vmenetN` whose MAC is unknown can't be matched directly, so use the bridge whose member set
  gained a `vmenet*` between a snapshot taken before `bootstrap` and one taken after it. Pass
  that bridge as `containerBridge`.

- [ ] **Step 1: Spike.** On this Mac, print `bridgeMembers()` and compare it with `ifconfig bridge100 bridge101 | grep member`. If they don't match exactly, stop, revert, and note "rule 2 not implemented" in the PR notes.
- [ ] **Step 2: Test** `bridgeMembersIncludesVmenet`. It runs only when some `bridge*` exists (`.enabled(if:)`), and expects every `bridge*` that has members to list at least one `vmenet*`.
- [ ] **Step 3: Implement the before/after snapshot** in `NetworkStartCheck`. Re-run Task 6 Step 3, items 1–4: the "which network?" question should no longer appear.
- [ ] **Step 4: Checkpoint.**

---

### Task 10: Final verification and folder rename

- [ ] **Step 1:** Run `make BUILD_CONFIGURATION=debug test`. Expect 0 failures, and record the total.
- [ ] **Step 2:** Re-run the Task 6 Step 3 acceptance list end-to-end with the installed package.
- [ ] **Step 3:** Rename the folder only if the user approves. It is already named
  `container-main-nat-patched`; if the user has renamed it to `…-nat-not-patched` in the
  meantime, rename it back and update `../REPAIR_README.md`.
- [ ] **Step 4:** Report to the user: the test count, the acceptance results, the deviations
  (`--rm` stated generally; rule 2 status), and the backup and history file locations.
