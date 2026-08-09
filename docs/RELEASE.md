# Release process

SpruceMyMac is distributed outside the Mac App Store as a GPL-3.0 application.
Every binary release must be accompanied by its corresponding source archive,
the pinned Mole source, licenses, checksums, and build instructions.

## Prerequisites

- Xcode 16 or newer
- XcodeGen
- For signed releases only: a `Developer ID Application` certificate, Apple
  Developer Team ID, and notarytool keychain profile

Store notarization credentials in the login keychain, never in the repository:

```bash
xcrun notarytool store-credentials SpruceMyMac-Notary \
  --apple-id you@example.com \
  --team-id YOUR_TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

## Build and sign

Start from a clean, tagged commit with the Mole submodule initialized:

```bash
git submodule update --init --recursive
export DEVELOPMENT_TEAM=YOUR_TEAM_ID
export CODE_SIGN_IDENTITY='Developer ID Application: Your Name (YOUR_TEAM_ID)'
Scripts/build-release.sh
```

The build script creates a clean Release archive for `arm64` and `x86_64`,
embeds the pinned Mole engine, and runs the release verifier. The verifier
rejects ad-hoc signatures, missing hardened-runtime flags, incomplete legal
documents, wrong engine revisions, and non-Universal binaries.

For an unsigned GitHub community build, use:

```bash
Scripts/build-release.sh --unsigned
Scripts/package-dmg.sh release/SpruceMyMac.app release/SpruceMyMac.dmg
```

Unsigned builds are not submitted to Apple and may require users to right-click
the app and choose Open. They contain no privileged helper or persistent root
service.

## Package and notarize

```bash
Scripts/package-dmg.sh release/SpruceMyMac.app release/SpruceMyMac.dmg
export NOTARYTOOL_PROFILE=SpruceMyMac-Notary
Scripts/notarize-release.sh release/SpruceMyMac.dmg
```

`notarize-release.sh` waits for Apple, staples and validates the ticket, runs a
Gatekeeper assessment, and regenerates the SHA-256 checksum after stapling.

## Corresponding source

The source archive command requires a clean committed worktree and expands the
Mole submodule into the archive rather than leaving a Git link:

```bash
Scripts/source-archive.sh release/SpruceMyMac-source.tar.gz
```

Publish together:

- `SpruceMyMac.dmg`
- `SpruceMyMac.dmg.sha256`
- `SpruceMyMac-source.tar.gz`
- `SpruceMyMac-source.tar.gz.sha256`
- release notes for the matching tag

Pushing a version tag such as `v0.1.0` runs
`.github/workflows/release.yml`. It validates that the tag matches
`MARKETING_VERSION`, runs the tests, builds the unsigned Universal 2 app,
verifies the DMG and source archive, and uploads all four files to a GitHub
Release. The repository must allow GitHub Actions to write repository contents.

## Independent engine releases

The App version, SpruceMyMac engine package version, upstream Mole commit, and
NDJSON protocol version are separate values. Engine package compatibility and
provenance are owned by `Engine/UPSTREAM.json`; a Mole tag alone is never an
engine compatibility promise.

Create an Ed25519 signing key on a trusted machine:

```bash
Scripts/generate-engine-signing-key.sh /secure/offline/engine-private.key \
  > /secure/offline/engine-public.txt
```

The private file is raw key material encoded as base64 and is created with mode
`0600`. Never commit it, attach it to a release, print it in CI, or store it in
an ordinary repository variable. Configure:

- Create a protected GitHub Environment named `engine-signing`, require at
  least one human reviewer, and store `ENGINE_SIGNING_PRIVATE_KEY` as an
  environment-scoped secret containing the private file's single base64 line.
- Store `ENGINE_SIGNING_PUBLIC_KEY` as a GitHub Actions variable containing the
  public base64 line. The App release workflow embeds this public key into
  `Info.plist`; the same key must verify the manifest produced by the engine
  release workflow.

The dedicated workflow is tag-only. An `engine-v<version>` tag must point to a
commit contained in `origin/main`; the workflow refuses unprotected side
commits before exposing the signing secret. GitHub-hosted signing still places
raw key material in an online runner and therefore depends on protected-branch,
environment-review, and Actions security. A hardware/KMS-backed signer where
the raw private key never enters Actions is the preferred future hardening.

A missing public variable intentionally produces an App with manual engine
updates disabled. Before publishing an update-enabled App, inspect the built
artifact rather than only the build environment:

```bash
/usr/libexec/PlistBuddy -c 'Print :SpruceEngineSigningPublicKey' \
  build/release/SpruceMyMac.app/Contents/Info.plist
```

A local release can be produced and verified with:

```bash
export ENGINE_SIGNING_PRIVATE_KEY_FILE=/secure/offline/engine-private.key
export ENGINE_SIGNING_PUBLIC_KEY="$(cat /secure/offline/engine-public.txt)"
Scripts/package-engine.sh build/engine-release
Scripts/verify-engine-package.sh build/engine-release "$ENGINE_SIGNING_PUBLIC_KEY"
Engine/Tests/engine_package_test.sh
```

Push an `engine-v<version>` tag matching `.engineVersion` in
`Engine/UPSTREAM.json`. The workflow derives a deterministic publication time
from that tagged commit and publishes these immutable versioned assets:

- `SpruceMyMac-Engine-<version>.tar.gz`
- `SpruceMyMac-Engine-<version>-source.tar.gz`
- `SpruceMyMac-Engine-<version>-manifest.json`
- `SpruceMyMac-Engine-<version>-manifest.sig`
- SHA-256 checksum files for all four

The separate prerelease tag `engine-feed` contains only mutable aliases named
`engine-manifest.json` and `engine-manifest.sig`, available at:

```text
https://github.com/Van426326/SpruceMyMac/releases/download/engine-feed/engine-manifest.json
https://github.com/Van426326/SpruceMyMac/releases/download/engine-feed/engine-manifest.sig
```

Authenticity comes from the pinned Ed25519 public key, not from the mutability
or TLS location of this pointer. Archive and source URLs inside the signed
manifest always refer to the immutable `engine-v<version>` release.

Every engine archive is a distribution of the modified GPL engine and must keep
its matching source archive, signature, manifest, notices, patches, overlay,
and build scripts available. Do not delete or overwrite versioned source assets
when publishing a newer engine. Key rotation, revocation, or loss requires an
App release that pins an approved replacement trust root; never place a new
public key only inside the remotely signed manifest.

The engine release workflow is independent of the App release workflow. Missing
engine signing secrets make only the dedicated engine workflow fail closed;
normal App releases remain unchanged. On retry, deterministic archives,
manifest, and checksum assets must match byte-for-byte; the already-published
signature is cryptographically reverified and reused because CryptoKit signing
may produce a different valid signature for the same bytes. The feed step
verifies its current signature, permits an identical-version repair only when
the manifest bytes match, and refuses to replace a newer semantic version with
an older one. If a two-asset upload was interrupted, a retry repairs the pair
only when either the published manifest or signature exactly matches the
verified candidate; an unrelated invalid pair still fails closed. This allows
a transient feed-upload failure to be repaired without deleting or replacing
the immutable release.

Downloaded engine trees and `EngineState.json` are user-owned. Runtime hashes,
private directory modes, ownership checks, and a monotonic version high-water
mark reduce accidental corruption and signed-feed replay, but they do not make
Application Support a trust boundary against malware already running as the
same macOS user. The current implementation also retains bounded in-memory
archive downloads and uses system `tar` only after signature/hash verification;
descriptor-bound extraction, streaming downloads, signed Mach-O payloads,
transparency logs, and threshold keys remain future hardening work.

## Manual acceptance

On a clean supported Mac:

1. Verify the downloaded checksum.
2. Mount the DMG and drag SpruceMyMac to `/Applications`.
3. Launch every main page in both Simplified Chinese and English.
4. Generate but cancel a cleanup plan; verify nothing moves.
5. Move a disposable test candidate to Trash and restore it.
6. Open the system-command assistant and verify both fixed commands can be
   copied without execution.
7. Open Settings and confirm the bundled engine version and Mole commit are
   shown. For a build without a configured public key, confirm update checking
   is visibly disabled rather than accepting unsigned data.
8. For an update-enabled build, publish a disposable higher engine version,
   manually check for it, inspect its source link, install it, restart the App,
   and confirm Settings still reports the downloaded version. Tampering with
   either feed asset must produce a verification error without changing the
   active version.
9. Restore the bundled engine from Settings and confirm subsequent operations
   use it. If testing fallback, corrupt only a disposable downloaded fixture
   and confirm resolution uses the verified previous version or bundled engine.
10. Confirm the app contains no `Contents/Library/HelperTools` or
    `Contents/Library/LaunchDaemons` payload.
11. For signed releases, run
    `spctl --assess --type execute --verbose=2 /Applications/SpruceMyMac.app`.

Never publish a signed build that bypasses a failed signing, notarization, or
Gatekeeper check. No build may bypass an engine, localization, or
corresponding-source check.
