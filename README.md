# ward-vendor

Pre-built **libkrun** + **libkrunfw** binaries.

This repo contains build scripts and CI workflows that produce relocatable
libkrun/libkrunfw binaries (`.dylib` for macOS, `.so` for Linux) and publish
them to GitHub Releases tagged `libkrun-v<version>`.

## Layout

```
.
├── README.md
├── LICENSE
├── version.txt            pinned libkrun release tag
├── libkrunfw-version.txt  pinned libkrunfw release tag
├── build.sh               builds libkrun + libkrunfw for the host platform
├── checksums.txt          SHA-256 sums per target tarball
└── .github/workflows/build.yml
```

## How to bump libkrun

1. Edit `version.txt` to the new version (no `v` prefix, just the number).
2. Commit + push.
3. Trigger the **build** workflow from the Actions tab (`workflow_dispatch`).
4. When the run completes, the workflow publishes a release tagged
   `libkrun-v<new>` with one tarball per supported triple plus matching
   `.sha256` sidecars.
5. Copy the SHA-256 sums from the workflow's Job Summary into
   `checksums.txt`, commit, push.

## Supported targets

- `aarch64-apple-darwin` (macOS Apple Silicon)
- `x86_64-unknown-linux-gnu` (Linux amd64)
- `aarch64-unknown-linux-gnu` (Linux arm64)

## Using a release

Each `libkrun-v<version>` release carries one tarball per target triple plus a
matching `.sha256` sidecar. To consume one:

1. Download the tarball for your triple and verify its checksum against the
   sidecar, `sha256sum -c <tarball>.sha256` (Linux) or
   `shasum -a 256 -c <tarball>.sha256` (macOS), or against `checksums.txt`.
2. Extract it: `tar -xzf <tarball> -C <prefix>`. This yields:
   ```
   lib/libkrun.{dylib,so}      relocatable, @rpath / $ORIGIN install names
   lib/libkrunfw.{dylib,so}    same
   lib/pkgconfig/libkrun.pc    synthesised, placeholder prefix
   include/libkrun.h
   ```
3. Rewrite the `__VENDOR_PREFIX__` placeholder in `lib/pkgconfig/libkrun.pc`
   to your extraction prefix before using `pkg-config`.
4. **Runtime:** libkrun loads libkrunfw by bare name (`libkrunfw.5.dylib` /
   `libkrunfw.so.5`), so keep both libraries in the same directory and make
   that directory discoverable by the dynamic loader, via the consuming
   binary's rpath (`@loader_path` / `$ORIGIN`) or `DYLD_LIBRARY_PATH` /
   `LD_LIBRARY_PATH`.

## Licence

The build scripts in this repo are Apache-2.0 (matching upstream
libkrun, since they're trivial glue around its build system). The
produced binaries inherit libkrun's licence: Apache-2.0.

The `libkrun-v<version>` releases are tagged but not separately
licensed beyond the licences of their constituent parts.
