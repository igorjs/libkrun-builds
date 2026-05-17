# ward-vendor

Pre-built **libkrun** + **libkrunfw** binaries.

This repo contains build scripts and CI workflows that produce relocatable
libkrun/libkrunfw binaries (`.dylib` for macOS, `.so` for Linux) and publish
them to GitHub Releases tagged `libkrun-v<version>`.

## Layout

```
.
├── README.md
├── version.txt        pinned libkrun version
├── build.sh           builds libkrun + libkrunfw for the host platform
├── checksums.txt      SHA-256 sums per target tarball
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

## Licence

The build scripts in this repo are Apache-2.0 (matching upstream
libkrun, since they're trivial glue around its build system). The
produced binaries inherit libkrun's licence: Apache-2.0.

The `libkrun-v<version>` releases are tagged but not separately
licensed beyond the licences of their constituent parts.
