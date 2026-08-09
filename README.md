# SpruceMyMac

SpruceMyMac is an independent, open-source macOS cleanup and storage-inspection app. It is built with SwiftUI and uses a versioned, structured bridge to the cleaning capabilities of [tw93/Mole](https://github.com/tw93/Mole).

The current build provides the native app shell, live system storage and memory
metrics, immutable cleanup plans, recoverable Trash execution, application
uninstall, progressive space analysis, fixed-scope tools, operation history,
user-managed protection rules, and a system-command assistant for fixed system
maintenance tasks. The bundled engine is based on a pinned Mole revision and
communicates through a versioned NDJSON protocol.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Download

Download the latest `SpruceMyMac.dmg` from
[GitHub Releases](https://github.com/Van426326/SpruceMyMac/releases/latest).
The community build is unsigned and supports both Apple silicon and Intel Macs.
After dragging the app to `/Applications`, the first launch may require
Control-clicking the app, choosing **Open**, and confirming once.

SHA-256 checksum files and the complete corresponding GPL source archive are
published beside every DMG.

## Build

```bash
xcodegen generate
xcodebuild -project SpruceMyMac.xcodeproj -scheme SpruceMyMac -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
```

Unsigned builds are suitable for local use and GitHub community distribution.
Users may need to right-click the app and choose Open because the build is not
notarized.

Run all checks and create an unsigned Universal 2 validation build with:

```bash
Scripts/verify-localization.sh
xcodebuild -quiet -project SpruceMyMac.xcodeproj -scheme SpruceMyMac -configuration Debug -derivedDataPath build/TestDerivedData test CODE_SIGNING_ALLOWED=NO
Scripts/build-release.sh --unsigned --output build/validation-release
```

Developer ID signing, DMG creation, notarization and corresponding-source
packaging are documented in [`docs/RELEASE.md`](docs/RELEASE.md).

## Project status

The first implementation phase is complete and release-ready. Destructive actions are never
automatic: the user reviews candidates, confirms the action, and the engine
moves selected items to the macOS Trash. Plans are rejected if they expire,
leave their command-specific allowed roots, are replayed, become whitelisted,
or no longer match their original filesystem identity.

The UI source language is Simplified Chinese and every shipped string has an
English fallback. The app icon source master is kept in
[`Brand/SpruceMyMac-AppIcon.svg`](Brand/SpruceMyMac-AppIcon.svg).

## Prepare the Mole engine

The repository records a reproducible Mole input rather than tracking an
unreviewed moving branch:

```bash
git submodule update --init --recursive
Scripts/prepare-engine.sh Vendor/Mole build/Engine/Mole
Engine/Tests/gui_plan_test.sh build/Engine/Mole
```

During development, set `SPRUCE_ENGINE_PATH` in the Xcode scheme to the
prepared `build/Engine/Mole/bin/gui.sh`. If no prepared engine is present, the
app uses its local read-only scanner. Release packaging will copy the complete
prepared engine into `SpruceMyMac.app/Contents/Resources/Engine/Mole`.

The internal commands currently implemented are:

```bash
gui.sh clean-plan --format ndjson --no-auth
gui.sh app-list --format ndjson --no-auth
gui.sh uninstall-plan --inventory-id <id> --app-id <id> --format ndjson --no-auth
gui.sh tool-plan --tool developer --format ndjson --no-auth
gui.sh apply-plan --plan-id <id> --items <id,id> --format ndjson --no-auth
```

All apply operations accept opaque candidate IDs only, revalidate the complete
selection before moving anything, atomically consume the plan to prevent
replay, and route removals through Mole's Trash deletion funnel.

## Manual engine updates

The Settings window can manually check for a newer SpruceMyMac Engine package.
Downloaded engines are accepted only after an embedded Ed25519 public key
verifies the signed manifest, every payload file matches that manifest, and the
engine reports a protocol and App-build range compatible with this build. The
active and previous versions are stored under
`~/Library/Application Support/SpruceMyMac/Engines`; the immutable engine in
the App bundle remains the final fallback.

No signing key is committed to this repository. Builds without an
`ENGINE_SIGNING_PUBLIC_KEY` safely disable the Check for Updates button, ignore
downloaded engines that cannot be authenticated without that trust root, and
continue using the bundled engine. They never fall back to an unsigned update.
Release-key provisioning and Engine package publication are documented in
[`docs/RELEASE.md`](docs/RELEASE.md).

## System maintenance commands

The GitHub build does not install a privileged helper or persistent root
service. Its system-command assistant displays two fixed, auditable commands
for refreshing the DNS cache and requesting a Spotlight index rebuild. The app
can copy a command and open Terminal, but it never runs `sudo`, reads an
administrator password, or constructs a command from user input. The user
reviews, pastes, and runs the command directly in Terminal.

## Independence notice

SpruceMyMac is not affiliated with or endorsed by Apple Inc., the Mole project, or Mole for Mac. Mac is a trademark of Apple Inc.

## License

Copyright (C) 2026 Van426326 and contributors.

SPDX-License-Identifier: GPL-3.0-only. See [LICENSE](LICENSE).
