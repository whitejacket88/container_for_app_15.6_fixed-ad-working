# Repair and Verification Notes

This document records the repairs applied to the extracted `container` source archive and the checks performed on an Apple Silicon Mac running macOS 15.6.1.

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

## Verification performed

On macOS 15.6.1, Apple Silicon:

```text
Full build: passed
Tests: 956 passed in 100 suites
Installer package: generated successfully
Runtime status: running
```

The generated package is unsigned because it was built locally with the debug configuration. A production distribution should use the project’s official signed release package or the project’s documented signing process.

## Build from this directory

```bash
cd ~/Downloads/container-main_fixed_for_15.6
make BUILD_CONFIGURATION=debug test
make BUILD_CONFIGURATION=debug installer-pkg
```

The package is written to:

```text
bin/debug/container-installer-unsigned.pkg
```

## Install the locally built package

```bash
cd ~/Downloads/container-main_fixed_for_15.6
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

## Security and distribution notes

- Do not publish API keys, registry credentials, signing certificates, private logs, or personal filesystem paths.
- Prefer signed release packages for normal use.
- Treat the locally generated package as a development artifact.
- Keep the original source archive as a clean backup and publish only the patched source or a clearly labeled patch release.

