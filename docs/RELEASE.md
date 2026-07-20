# Release process

SpruceMyMac is distributed outside the Mac App Store as a GPL-3.0 application.
Every binary release must be accompanied by its corresponding source archive,
the pinned Mole source, licenses, checksums, and build instructions.

## Prerequisites

- Xcode 16 or newer
- XcodeGen
- A `Developer ID Application` certificate
- An Apple Developer Team ID
- A notarytool keychain profile

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
embeds the pinned Mole engine and privileged helper, and runs the release
verifier. The verifier rejects ad-hoc signatures, missing hardened-runtime
flags, incomplete legal documents, wrong helper identifiers, wrong engine
revisions, and non-Universal binaries.

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

## Manual acceptance

On a clean supported Mac:

1. Verify the downloaded checksum.
2. Mount the DMG and drag SpruceMyMac to `/Applications`.
3. Launch every main page in both Simplified Chinese and English.
4. Generate but cancel a cleanup plan; verify nothing moves.
5. Move a disposable test candidate to Trash and restore it.
6. Register the system helper, approve it in System Settings, and run the DNS
   refresh task.
7. Confirm the Spotlight task shows its higher-impact confirmation; running it
   is optional for release acceptance.
8. Unregister the helper and confirm maintenance buttons become disabled.
9. Run `spctl --assess --type execute --verbose=2 /Applications/SpruceMyMac.app`.

Never publish a build that bypasses a failed signing, notarization, Gatekeeper,
helper, engine, localization, or corresponding-source check.
