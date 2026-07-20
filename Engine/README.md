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

The pinned revision is recorded in `UPSTREAM.json`. A prepared source tree can
be assembled with `Scripts/prepare-engine.sh` after that exact Mole revision is
available locally.

`Patches/0001-configurable-log-directory.patch` keeps Mole's existing log
implementation but allows the bundled engine to write beneath
`~/Library/Logs/SpruceMyMac` instead of sharing the CLI's state directory.
