# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities in this repository (the build
scripts, CI workflows, or the published binaries) privately via GitHub's
[Security Advisories](https://github.com/igorjs/libkrun-builds/security/advisories/new)
feature. Don't open a public issue.

Expected response timeline:

| Stage | Target |
|---|---|
| Initial acknowledgement | Within 7 days |
| Triage and analysis     | Within 14 days |
| Fix or detailed resolution | Within 30 days for confirmed reports |

Critical issues (remote code execution in the build pipeline, supply-chain
compromise of upstream verification, signing-key exposure, compromise of
the `igorjs` GitHub App identity) are prioritised over the standard
cadence and handled out-of-band.

## Scope

### In scope

- Vulnerabilities in `build.sh` or the CI workflows that could produce
  compromised release artefacts.
- Issues with the SHA verification, build provenance attestation, or
  cosign signing pipeline that could let an attacker publish bytes
  consumers would verify as legitimate.
- Tampering paths against `upstream-checksums.txt`, `checksums.txt`, or
  workflow secrets.
- Compromise of the `igorjs` GitHub App identity that affects this
  repo's releases.
- Bypass of the main-branch or tag-protection rulesets.

### Out of scope

- **Vulnerabilities in upstream libkrun or libkrunfw.** Report those to
  [containers/libkrun](https://github.com/containers/libkrun/security/advisories)
  or [containers/libkrunfw](https://github.com/containers/libkrunfw/security/advisories)
  instead. This repo only re-packages upstream binaries; it cannot patch
  them.
- Issues that require an attacker to already have admin or write access
  to this repository.
- Theoretical issues without a practical exploit path.
- Bug reports about libkrun's runtime behaviour or microVM isolation.
  Those belong upstream.

## Verifying a release

Three independent verification paths are published with every release.
See the README's [Using a release](./README.md#using-a-release) section
for full commands. In summary:

| Path | Tool | What it proves |
|---|---|---|
| SHA-256 | `sha256sum -c <tarball>.sha256` | The tarball wasn't modified in transit. |
| Build provenance attestation | `gh attestation verify <tarball> --repo igorjs/libkrun-builds` | The tarball was built by this specific workflow on this specific commit. |
| Cosign keyless signature | `cosign verify-blob --signature <tarball>.sig --certificate <tarball>.pem ...` | The tarball was signed by a workload with this repo's OIDC identity. |

For maximum confidence, run all three. The attestation path is the
strongest end-to-end guarantee because it binds the artefact to the
exact source commit and workflow run.

## Supported versions

Only the latest `libkrun-v<n>` release receives security updates. Older
releases aren't back-ported. If a vulnerability is found in an older
binary, upgrade to the latest release.

When a new upstream `libkrun` or `libkrunfw` version lands and the
watcher publishes the corresponding `libkrun-v<new>` release, the
previous release is left in place but considered superseded for
security purposes.

## Hardening posture

For the full security architecture of the build pipeline (SHA-pinned
actions, harden-runner, App-token bot identity, attestation +
cosign self-verify, ruleset-as-code via the separate `repo-config` repo,
etc.), see the [Hardening posture](./README.md#hardening-posture)
section of the README.

## Coordinated disclosure

If your report affects both this repo and upstream libkrun / libkrunfw,
please file with both projects simultaneously. We'll coordinate the
release of any fix with upstream where the vulnerability is shared.
