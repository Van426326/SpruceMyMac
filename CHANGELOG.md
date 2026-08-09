# Changelog

All notable changes to SpruceMyMac are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## 0.2.2 - 2026-08-09

### Changed

- Replace the macOS application icon with the new glass spruce artwork.
- Use the same application icon in the sidebar brand and About view.

## 0.2.1 - 2026-08-09

### Fixed

- Restore bundled Engine discovery by providing the required user environment
  during the compatibility handshake.
- Keep the read-only `engine-info` handshake independent of `HOME` initialization.

## 0.2.0 - 2026-08-09

### Added

- Manual in-app updates for SpruceMyMac-signed Mole engine packages.
- Versioned active, previous, and bundled engine resolution with safe rollback.
- Engine compatibility, capability, architecture, App-build, and anti-downgrade checks.
- Deterministic signed engine releases with matching GPL corresponding-source assets.

### Changed

- Destructive engine execution now preserves terminal partial results and is never
  automatically retried after launch.
- Read-only Mole operations use race-safe, operation-specific cancellation.

## 0.1.0 - 2026-07-20

### Added

- Native SwiftUI dashboard with live disk and memory metrics.
- Immutable smart-cleanup plans with fingerprint revalidation and Trash-only
  execution through a pinned Mole engine.
- Application inventory, protected-app handling, and exact leftover plans.
- Progressive space analysis with Quick Look, Finder reveal, and recoverable
  removal.
- Developer-cache and installer tools, protection rules, and local history.
- System-command assistant for copying fixed DNS and Spotlight maintenance
  commands without installing a root service or handling administrator credentials.
- Simplified Chinese source language and English localization.
- Universal 2 release, signing, notarization, DMG, source-archive, and CI
  workflows.
