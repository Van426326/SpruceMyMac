# SpruceMyMac

SpruceMyMac is an independent, open-source macOS cleanup and storage-inspection app. It is built with SwiftUI and uses a versioned, structured bridge to the cleaning capabilities of [tw93/Mole](https://github.com/tw93/Mole).

The current build provides the native app shell, live system storage and memory
metrics, immutable cleanup plans, recoverable Trash execution, application
uninstall, progressive space analysis, fixed-scope tools, operation history,
user-managed protection rules, and a signed-XPC design for fixed system
maintenance tasks. The bundled engine is based on a pinned Mole revision and
communicates through a versioned NDJSON protocol.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

```bash
xcodegen generate
xcodebuild -project SpruceMyMac.xcodeproj -scheme SpruceMyMac -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
Scripts/verify-helper.sh build/Build/Products/Debug/SpruceMyMac.app
```

Unsigned builds are suitable for tests and UI development, but macOS will not
register their LaunchDaemon.

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

## Privileged system maintenance

The app embeds a dedicated `sprucemymac-helper` LaunchDaemon for two compiled,
fixed-argument tasks: refreshing the DNS cache and requesting a Spotlight index
rebuild. The XPC connection validates designated code-signing requirements in
both directions and accepts only a task ID plus a UUID request ID. It never
accepts arbitrary commands or paths; direct command-line task execution is
rejected.

Activation requires the app to be installed in `/Applications`, signed with
the hardened runtime, notarized, registered through `SMAppService`, and
approved by an administrator in System Settings. See
[`Helper/SECURITY.md`](Helper/SECURITY.md) for the threat model and exact task
catalog.

## Independence notice

SpruceMyMac is not affiliated with or endorsed by Apple Inc., the Mole project, or Mole for Mac. Mac is a trademark of Apple Inc.

## License

Copyright (C) 2026 Van426326 and contributors.

SPDX-License-Identifier: GPL-3.0-only. See [LICENSE](LICENSE).
