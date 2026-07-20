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

## Manual acceptance

On a clean supported Mac:

1. Verify the downloaded checksum.
2. Mount the DMG and drag SpruceMyMac to `/Applications`.
3. Launch every main page in both Simplified Chinese and English.
4. Generate but cancel a cleanup plan; verify nothing moves.
5. Move a disposable test candidate to Trash and restore it.
6. Open the system-command assistant and verify both fixed commands can be
   copied without execution.
7. Confirm the app contains no `Contents/Library/HelperTools` or
   `Contents/Library/LaunchDaemons` payload.
8. For signed releases, run
   `spctl --assess --type execute --verbose=2 /Applications/SpruceMyMac.app`.

Never publish a signed build that bypasses a failed signing, notarization, or
Gatekeeper check. No build may bypass an engine, localization, or
corresponding-source check.
