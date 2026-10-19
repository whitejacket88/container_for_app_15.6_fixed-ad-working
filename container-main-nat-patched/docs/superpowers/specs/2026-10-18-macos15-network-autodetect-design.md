# macOS 15 Network Range Auto-Detect and Repair — Design

Date: 2026-10-18
Status: Approved 2026-10-18

## Intent

On macOS 15, `container` cannot choose the vmnet subnet. The network plugin runs the
`AllocationOnlyVmnetNetwork` variant, which hands out container IPs from
`[network] subnet` in config.toml, or from the hard-coded default `192.168.64.1/24`
(`Sources/Services/NetworkVmnet/Server/AllocationOnlyVmnetNetwork.swift:26`). The Mac's real
shared vmnet range is set system-wide in
`/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist` (`Shared_Net_Address`), and
other tools can move it. QEMU-based tools such as Multipass are the likely cause.

When the two ranges disagree, containers start "successfully", get an IP, and have **no network
at all**: the gateway does not exist on the host (`No route to host`), so DNS and `apt` fail.
Nothing in `container` says why. This happened on the author's Mac: the system range was
`192.168.253.1` and the container got `192.168.64.2`. The manual fix was adding
`[network] subnet = "192.168.253.1/24"` to `~/.config/container/config.toml` and restarting
services.

**Who this is for:** someone who installed the compiled package, whose containers have no
internet, and who does not know how to troubleshoot it. The product should notice, fix
`container`'s side, and explain in plain words what happened.

## Goals

1. Detect the mismatch automatically on macOS 15, with no password in the normal path.
2. Tell the user clearly what is wrong, and let them choose. They can repair automatically,
   update the setting and restart later, or do nothing. Nothing changes without their choice.
   *(User's decision.)*
3. Never make things worse. Back up before changing anything, verify after, and roll back if
   verification fails.
4. Give users a self-service diagnostic command: `container system network check`.

## Non-goals

- Changing the Mac's system vmnet setting (`com.apple.vmnet.plist`). `container` follows the Mac
  and never the reverse. The user explicitly chose this over "revert the Mac setting".
- Touching other VM tools (Multipass, Docker, Colima, UTM, …).
- Any behavior change on macOS 26+. There the `ReservedVmnetNetwork` variant sets the subnet
  itself, so this whole feature is gated to the `allocationOnly` variant / macOS < 26.
- IPv6.
- A "restore/revert to a previous config" feature beyond the automatic rollback in Goal 3.

## Anti-goals (failure even if it "works")

- Prompting for a password during ordinary `container start` / `run`.
- Hanging on a prompt when stdin is not a TTY (scripts, CI, launchd).
- Killing an interactive session the user is currently attached to.
- Silently rewriting the user's config.toml in a way that loses their other settings or comments.
- Flapping: repeatedly "fixing" back and forth between two candidate ranges.

## Constraints and facts from the codebase

- Config layering (`Sources/ContainerPersistence/ConfigurationLoader.swift`):
  - The user source is `~/.config/container/config.toml`.
  - `container system start` copies it read-only to `<appRoot>/config/config.toml`
    (`SystemStart.swift:76`, `copyConfigurationToReadOnly`).
  - The system defaults are at `<installRoot>/etc/container/config.toml`. The doc comment at
    line 87 says `.../config/config.toml`; the builder must confirm the real path via
    `configurationFile(.installRoot)`.
  - Precedence: user (appRoot copy) > system (installRoot).
  - Changes take effect only after `container system stop && container system start`, because
    the APIServer reads `containerSystemConfig.network.subnet` at startup
    (`APIServer+Start.swift:328`).
- `NetworkConfig` already has `subnet: CIDRv4?` (`ContainerSystemConfig.swift:231`). No schema
  change is needed.
- The top-level `container network` command group is macOS 26-only
  (`Application.swift:164`). The new diagnostic therefore lives under `container system`.
- `SystemStart` already has an interactive prompt precedent: the kernel install `[Y/n]` prompt
  with an `--enable/--disable-kernel-install` flag (`SystemStart.swift:56,179-191`). The new
  prompts should follow the same style.
- `com.apple.vmnet.plist` is `root:wheel 0640`, so it is unreadable without admin rights.
- Interface addresses (`getifaddrs`) are readable by anyone. When a VM attaches to shared vmnet,
  macOS creates or uses a `bridgeN` interface whose IPv4 address is the real shared gateway
  (observed: `bridge101 192.168.253.1`).
- Several `bridgeN` interfaces can exist at once. On the author's Mac, `bridge100 192.168.252.1`
  belonged to a Multipass/QEMU VM, alongside the real shared bridge. Detection must not assume
  "the only bridge".
- Containers get static IPs from `container`'s allocator, not DHCP.

## Design

### 1. Detection core (pure, unit-testable)

A pure function, roughly:

```
diagnose(configuredSubnet: CIDRv4,
         hostInterfaces: [(name, ipv4, netmask)],
         systemSharedAddress: IPv4Address?   // only when known via the --admin read
        ) -> Diagnosis
```

`Diagnosis` is one of:

- `.ok`: some host interface holds the configured gateway (`subnet.lower + 1`, matching
  `AllocationOnlyVmnetNetwork.start()`), **and** that interface is the authoritative one whenever
  an authoritative signal exists. If the system address is known (rule 1), it must match. If
  bridge membership is available (rule 2), the gateway must be on the container's bridge. This
  stops a wrong earlier choice, such as pointing at a Multipass bridge, from reading as `.ok`
  forever. *(Designer's call.)*
- `.mismatch(suggested: CIDRv4, evidence: String)`: there is a single best candidate.
- `.ambiguous(candidates: [CIDRv4])`: several bridges are plausible and nothing distinguishes
  them.
- `.undetermined`: no bridge exists yet and the system address is unknown. This is normal
  before any VM has started.

Candidate selection rules, in order:

1. If `systemSharedAddress` is known, it wins outright.
2. Otherwise, use the bridge that has the container's host-side `vmenetN` interface as a member.
   This is the most precise no-password signal. How to read bridge membership is the builder's
   call; see "Left to the builder".
3. Otherwise, if exactly one `bridgeN` has an IPv4 address in RFC1918 space, use it.
4. Otherwise, the result is `.ambiguous`.

Host-interface enumeration and the plist read are thin, injectable adapters, so the core is
tested without a real network.

### 2. Automatic check at container start (no password, user decides)

Where: the CLI, in `ContainerStart` and `ContainerRun`, after `client.bootstrap(...)` succeeds.
The bridge only exists once a VM has attached, which is why the check runs then. It applies only
when the network plugin variant is `allocationOnly`, i.e. on macOS < 26.

Steps:

1. Get the container's attachment(s) on the default network (`Attachment.ipv4Gateway`).
2. Run `diagnose`.
   - **`.ok`:** do nothing and print nothing.
   - **`.mismatch` / `.ambiguous`:** show the notification and the choices below.
   - **`.undetermined`:** after attach, the expected bridge should exist, so print a warning
     ("container may have no network; run `container system network check --admin`"). It is
     not silent. Section 6 governs. *(Designer's call.)*
   - **What `diagnose` compares against:** always the subnet the *running* network reports
     (`Attachment.ipv4Gateway` / network status), never the file. If config.toml already holds
     the suggested subnet but services haven't been restarted (a "fix pending" state, recorded in
     `network-repair.json`), the check does not offer to re-write anything. It only repeats the
     "restart to apply" instruction, together with the restart choice. *(Designer's call.)*

3. **Notification and choices.** This is the user's decision: the user is always asked, and
   nothing is repaired silently. With a TTY:

   ```
   ⚠ Network problem: kali-gui has no network access.
     container is using 192.168.64.x, but your Mac's VM network is 192.168.253.x
     (probably changed by another app such as Multipass).

     Repairing updates container's settings and restarts container services.
     These running containers will be restarted: kali-gui, web-test

     [1] Repair automatically now
     [2] Update the setting only. I'll restart later (shows the commands)
     [3] Do nothing (shows the manual steps)
   ```

   - The restart list names **every** running container. `container system stop` stops all of
     them, not just the one being started. Mark containers that will be **deleted** rather than
     restarted (`--rm`) and ones with an interactive terminal (`initProcess.terminal == true`),
     so the user can see what they'd lose. With no other containers running, the list is just
     the current one.
   - **`.ambiguous`:** before the three choices, ask which network: a numbered list of candidate
     bridges (interface name and range) plus "I don't know: show me how to check". The last
     option prints the `--admin` / `sudo defaults read` command.
   - **[1]** runs the full Section 4 repair: back up, write, restart services, restart the
     listed non-`--rm` containers, verify, roll back on failure.
   - **[2]** runs Section 4 steps 1–2 only (back up and write), records "fix pending", and
     prints `container system stop && container system start && container start <ids>`.
   - **[3]** changes nothing and prints the manual steps (the `config.toml` snippet and restart
     commands).
   - If the current CLI invocation is itself an interactive session (`run -it`, `start -a -i`),
     the prompt is shown before attaching the user's terminal. Choosing [1] means this session
     starts after the repair.
   - Default on Enter: **[3]**, so nothing changes. *(Designer's call.)*

4. **Without a TTY** (scripts, CI): print the same notification, the candidates if ambiguous,
   and the manual fix commands. Change nothing, and never wait for input. Exit status of the
   start/run itself is unchanged: the container did start.
5. **Opt-out:** setting `[network] checkOnStart = false` in config.toml disables the
   start-time check entirely. `container system network check` still works. The default is
   `true`. *(Designer's call.)*

### 3. `container system network check` (self-service diagnostic)

This is a new subcommand group under `container system`, available on all macOS versions. On
macOS 26 it reports "managed automatically by macOS 26" and exits 0.

Output is plain-language and covers:

- the configured subnet and gateway;
- the host bridges found and which one the Mac is really using;
- for each running container on the default network, whether it can reach its gateway and
  whether DNS resolves (via a quick `exec` probe, e.g. `getent hosts` plus a TCP connect to the
  gateway, using bash's `/dev/tcp` or an equivalent that exists in minimal images);
- a one-line verdict.

Flags:

- With a TTY and no flags, if a problem is found it shows the same notification and
  [1]/[2]/[3] choices as Section 2.
- `--fix`: choose [1] without prompting, for scripts. It still refuses when the result is
  `.ambiguous`, unless `--subnet <cidr>` is given.
- `--subnet <cidr>`: use this range instead of the detected one.
- `--admin`: also read `com.apple.vmnet.plist` via `sudo /usr/bin/defaults read …
  Shared_Net_Address`. This prompts for a password through sudo, and passes the result as
  `systemSharedAddress`. It is the only path that can diagnose correctly before any VM is up.
- Exit codes: `0` ok, `1` mismatch (unfixed), `2` ambiguous or undetermined, `>2` error.
  *(Designer's call.)*

The notifications in Section 2 end with "Run `container system network check` for details."

### 4. Repair procedure (shared by Sections 2, 3, 5)

1. **Load-preserving edit:** update only `[network].subnet` in `~/.config/container/config.toml`,
   creating the file and directory if missing. Keep all other keys and comments; a minimal
   line-level TOML edit is acceptable if a round-trip writer would drop comments.
2. **Backup:** before writing, copy the existing file to
   `config.toml.bak-<ISO8601 timestamp>`. Keep the last 5. *(Designer's call.)*
3. **Apply:** restart services the same way `container system stop` / `start` do, then restart
   the affected containers that were running and non-interactive.
4. **Verify:** after restart, re-run `diagnose` against the new attachment. Success means a host
   interface now holds the gateway.
5. **Roll back on failure:** restore the backup, restart services again, and print what went
   wrong plus "run `container system network check --admin`".
6. **History:** record each repair (timestamp, from→to, choice made, pending or applied) in
   `<appRoot>/network-repair.json`. If a new suggestion would revert a change made within the
   last 10 minutes, the notification says so ("this was changed to X 3 minutes ago, so another
   app may be switching it back and forth"), so the user can choose with that in mind.
   *(Designer's call.)*
7. Log every repair through the existing logger, so it shows up in `container system logs`.

### 5. Installer

The installer is unchanged: there is no postinstall script. *(User's decision.)* The first
`container start` after install on an affected Mac shows the Section 2 notification. All network
fixes live in `~/.config/container/config.toml`.

### 6. Better error when a container can't reach its gateway

The existing start path stays the same apart from Section 2. On macOS 15, if the post-start
check returns anything other than `.ok`, the user gets a message instead of the silent failure
that happened today.

### 7. Docs

- `docs/networking.md`: a "macOS 15: VM network range" section covering the cause, the repair prompt,
  `checkOnStart`, and manual fix.
- `docs/command-reference.md`: `container system network check`.
- `REPAIR_README.md` (outside the source tree): once implemented, update section 3 from
  "designed, not yet implemented" to describe the shipped behavior, and update the folder layout
  table.

## Testing

- Unit tests for `diagnose`: ok; mismatch with one bridge; mismatch with the
  bridge-membership signal; several bridges → ambiguous; no bridges → undetermined;
  system address overrides everything; the gateway computation matches `AllocationOnly`.
- Unit tests for the config edit: creates the file; preserves other sections and comments;
  replaces an existing subnet; writes a backup; rotates to 5.
- Unit tests for the repair history and the "recently changed" note.
- Unit tests for the choice handling ([1]/[2]/[3], ambiguous selection, non-TTY path, default
  on Enter), with the prompt I/O injected.
- Manual acceptance on the author's Mac (macOS 15.6.1, Multipass present):
  - Remove `[network]` from config, restart, then `container start kali-gui`. Expect the
    notification. Bridges from both Multipass and the shared network are present, so expect the
    "which network?" question unless rule 2 resolves it. Choose [1] and expect working DNS and a
    backup file.
  - Repeat, choosing [2] (setting written, restart commands printed) and [3] (nothing changed).
  - Repeat with `container run -it`. Expect the prompt before attaching.
  - Repeat with stdin not a TTY. Expect the notification and commands, no prompt, no change.
  - Run `container system network check` and `--admin`, and check the output and exit codes.
- Existing suite (956 tests) still passes; macOS 26 behavior unchanged.

## Decisions from the user (2026-10-18)

- `container` follows the Mac's network range. It never changes the Mac's setting or other
  tools.
- On a detected problem, the user is shown the error and chooses: repair automatically, update
  only, or do nothing. There is no silent auto-repair.
- When two networks look equally likely, the user picks. Fully automatic detection on such
  Macs is not required, so rule 2 (bridge membership) is a nice-to-have, not a blocker.
- The installer makes no network changes. All fixes go through the prompt into the user's
  config.toml.

## Left to the builder

- How to read bridge membership (`SIOCGDRVSPEC`/`BRDGGIFS` ioctl, or another reliable method),
  and how to map the container to its host-side `vmenetN`. If no reliable approach exists,
  drop rule 2 and rely on rules 1, 3 and 4.
- Exact module placement. Suggestion: core in `ContainerResource` or a new small target; CLI in
  `ContainerCommands/System/Network/`.
- Exact wording of messages, keeping the plain-language tone above.
- Whether the gateway reachability probe in Section 3 uses `exec` or a lighter mechanism.
- TOML editing technique, as long as Section 4 step 1 holds.

## Designer's calls (for review)

These were not explicitly decided by the user:

- Pressing Enter at the prompt defaults to [3] Do nothing.
- The prompt is shown before attaching an interactive `run -it` session.
- The `[network] checkOnStart` opt-out defaults to on.
- `.ok` requires the authoritative bridge when one is known.
- `.undetermined` after start warns instead of staying silent.
- `diagnose` compares against the running network, and pending fixes are tracked.
- Exit codes for `network check`.
- Keep 5 backups.
- A 10-minute anti-flap window.
