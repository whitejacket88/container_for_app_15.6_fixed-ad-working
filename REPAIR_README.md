# Repair and Verification Notes

This document records the repairs applied to the extracted `container` source archive and the checks performed on an Apple Silicon Mac running macOS 15.6.1.

## Folder layout

| Folder | Contents |
|---|---|
| `container-main/` | Original, unmodified source. Keep as a clean backup. |
| `container-main_fixed_for_15.6/` | Build/test repairs below (sections 1–2). Builds an installer package, but containers may have no network (section 3). |
| `container-main-nat-patched/` | `_fixed_for_15.6` plus the macOS 15 networking fix (section 3). Build from here. |

## Problems found

### 1. Three alias tests failed on macOS 15

The failing tests were:

- `Aliases are carried to a later attachment`
- `Aliases from the network specification land on the attachment they were declared for`
- `Aliases in a network specification are qualified when the attachments are built`

The implementation was already intentionally guarded by an availability check. Non-default network configuration requires macOS 26 or newer, but the tests were being run unconditionally on macOS 15.6.1. The failures therefore represented an unsupported platform condition, not a broken alias implementation.

The three tests now return early on unsupported macOS versions. On macOS 26 or newer, they still execute normally.

### 2. ZIP archives were treated as Git checkouts

The original Makefiles called Git commands such as `git describe` and `git rev-parse`. An extracted ZIP has no `.git` directory, causing empty version data, noisy Git errors, and a malformed `pkgbuild` invocation.

The repair now:

- Resolves the project root from the Makefile location.
- Uses `0.0.0` when no Git tag is available.
- Uses `unknown` when no Git commit is available.
- Makes protobuf and pre-commit paths work from an archive as well as a Git checkout.

### 3. Containers had no network on macOS 15 (NAT subnet mismatch)

**Symptom:** containers start and receive an IP (for example `192.168.64.2`), but cannot reach their gateway (`No route to host`). DNS fails, so `apt update` and package installs fail.

**Cause:** on macOS 15 `container` cannot choose the vmnet subnet. It assumes the macOS default, `192.168.64.1/24` (`Sources/Services/NetworkVmnet/Server/AllocationOnlyVmnetNetwork.swift:26`). The Mac's real shared VM network is set system-wide in `/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist` (`Shared_Net_Address`). Other virtualization tools can change it; on the test Mac, a Multipass (QEMU) install moved it to `192.168.253.1`. The containers then pointed at a gateway that did not exist.

This was not caused by the build/test repairs above, which do not touch networking.

**Workaround (applied and verified on the test Mac):**

1. Read the Mac's actual shared network address. This requires admin, because the plist is root-only:

   ```bash
   sudo defaults read /Library/Preferences/SystemConfiguration/com.apple.vmnet Shared_Net_Address
   ```

2. If it is not `192.168.64.1`, set `container`'s subnet to match:

   ```bash
   mkdir -p ~/.config/container
   cat > ~/.config/container/config.toml <<'TOML'
   [network]
   subnet = "192.168.253.1/24"
   TOML
   ```

   Replace `192.168.253.1` with the value from step 1.

3. Restart the services, confirm the setting was loaded, then restart the containers:

   ```bash
   container system stop && container system start
   container system property list   # [network] should show the subnet
   container start <id>
   ```

   Containers get a new address on start. Recreating them is not necessary, and volumes are unaffected.

4. Verify:

   ```bash
   container exec <id> getent hosts http.kali.org
   ```

If another tool changes the Mac's shared network again, repeat the steps with the new value.

**Permanent fix (in `container-main-nat-patched`):**

- On macOS 15, `container start` and `container run` check whether the container's gateway exists on the Mac. If it doesn't, they show the problem and offer three choices: **[1] Repair automatically now**, **[2] Update the setting only**, or **[3] Do nothing**, which is the default.
- Repairing writes `[network] subnet` to `~/.config/container/config.toml` (with a backup), restarts the services and containers, verifies the result, and undoes the change if it didn't work.
- Without a terminal (scripts), it only prints the problem and the manual steps.
- `container system network check [--admin] [--fix] [--subnet <cidr>]` runs the same diagnosis on demand.
- `[network] checkOnStart = false` turns the start-time check off.
- The installer makes no network changes.

See `docs/networking.md` ("macOS 15: when containers have no network"). The design is in `docs/superpowers/specs/2026-10-18-macos15-network-autodetect-design.md` and the implementation plan in `docs/superpowers/plans/`.

## Verification performed

On macOS 15.6.1, Apple Silicon:

```text
Full build: passed
Tests: 956 passed in 100 suites (container-main_fixed_for_15.6)
Tests: 1016 passed in 108 suites (container-main-nat-patched, includes 60 networking tests)
Installer package: generated successfully
Runtime status: running
Container networking: required the section 3 workaround on the test Mac; verified working afterwards (DNS + internet from a Kali container)
```

The generated package is unsigned because it was built locally with the debug configuration. A production distribution should use the project’s official signed release package or the project’s documented signing process.

## Build from this directory

Run these from the folder that contains this README.

```bash
cd container-main-nat-patched
make BUILD_CONFIGURATION=debug test
make BUILD_CONFIGURATION=debug installer-pkg
```

The package is written to:

```text
bin/debug/container-installer-unsigned.pkg
```

## Install the locally built package

```bash
cd container-main-nat-patched
sudo installer -pkg ./bin/debug/container-installer-unsigned.pkg -target /
```

Then start and verify the runtime:

```bash
container system start
container system status
container run --rm alpine:latest uname -a
```

## Platform limitation

The runtime can build and run supported containers on the tested system, but non-default network configuration is unavailable on macOS 15.6.1. That functionality requires macOS 26 or newer and must not be represented as available merely because the source compiles.

On macOS 15, the default network also cannot follow the Mac's shared VM range automatically. Section 3 covers this. Use `[network] subnet` in `~/.config/container/config.toml` to match it.

## Security and distribution notes

- Do not publish API keys, registry credentials, signing certificates, private logs, or personal filesystem paths.
- Prefer signed release packages for normal use.
- Treat the locally generated package as a development artifact.
- Keep the original source archive as a clean backup and publish only the patched source or a clearly labeled patch release.

