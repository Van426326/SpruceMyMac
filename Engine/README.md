# SpruceMyMac engine overlay

The engine is built from a pinned Mole source revision plus the files in
`Overlay/`. The overlay is kept outside the app target so that upstream code,
local modifications, and the native UI remain easy to audit independently.

The first machine-facing command generates a read-only plan:

```bash
sprucemymac-engine clean-plan --format ndjson --no-auth
```

It scans only direct children of the invoking user's `~/Library/Caches`, runs
Mole's path and application-protection checks, rejects symbolic links, and
emits one JSON object per line. It never invokes `mole_delete`, `safe_remove`,
`sudo`, or an authorization prompt.

`apply-plan` accepts only a plan UUID and opaque candidate IDs. Plan files are
private, expire after 15 minutes, are consumed atomically, and are never
reusable. Every selected target is revalidated against its command-specific
root, device, inode, modification time, Mole protection policy, and the
SpruceMyMac whitelist before any item is moved. Execution uses
`MOLE_DELETE_MODE=trash` and Mole's `mole_delete` funnel; Trash failure never
falls back to permanent deletion.

The overlay also provides application inventory/uninstall plans and fixed-scope
developer-cache and installer plans. Apple applications are locked, shared
bundle identifiers suppress leftover discovery, and user-data candidates are
unselected by default.

## Version and compatibility metadata

`UPSTREAM.json` is the source of truth for the SpruceMyMac engine package
version, exact Mole commit, protocol versions, compatible App build range,
minimum macOS version, architectures, and capabilities. The engine package
version is owned by SpruceMyMac and is independent of the upstream Mole tag.
`Scripts/prepare-engine.sh` copies this file to `engine-info.json` in the
prepared tree.

A caller can inspect compatibility without loading Mole or creating state:

```bash
build/Engine/Mole/bin/gui.sh engine-info --format json
```

This command only reads the adjacent regular metadata file. All other commands
continue to use the versioned NDJSON protocol.

A prepared source tree can be assembled after the exact pinned revision is
available locally:

```bash
Scripts/prepare-engine.sh Vendor/Mole build/Engine/Mole
```

`Patches/0001-configurable-log-directory.patch` keeps Mole's existing log
implementation but allows the bundled engine to write beneath
`~/Library/Logs/SpruceMyMac` instead of sharing the CLI's state directory.

## Signed engine packages

An update release contains an immutable prepared-engine archive, matching GPL
corresponding-source archive, canonical JSON manifest, detached Ed25519
signature, and SHA-256 checksum files. The manifest is signed over its exact
bytes and records archive/source hashes and sizes plus the exact sorted list of
regular engine files. Symlinks and special files are rejected.

Generate an offline signing key once and keep the private file outside the
repository:

```bash
Scripts/generate-engine-signing-key.sh /secure/path/engine-private.key
# stdout is the raw public key in base64 form
```

Create and verify a package:

```bash
export ENGINE_SIGNING_PRIVATE_KEY_FILE=/secure/path/engine-private.key
export ENGINE_SIGNING_PUBLIC_KEY='<base64 public key>'
Scripts/package-engine.sh build/engine-release
Scripts/verify-engine-package.sh build/engine-release "$ENGINE_SIGNING_PUBLIC_KEY"
```

The private key is never included in an archive. Packaging fails closed when no
private key is supplied. `Engine/Tests/engine_package_test.sh` uses an ephemeral
key to exercise signing and tamper detection.
