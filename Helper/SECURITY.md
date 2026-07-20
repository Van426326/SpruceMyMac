# Privileged Helper security model

The SpruceMyMac privileged helper is a macOS LaunchDaemon registered with
`SMAppService`. It exists only to run a small, audited set of maintenance
operations that require root privileges. It is not a general command runner
and does not delete files.

## Trust boundary

- The app embeds the executable at
  `Contents/Library/HelperTools/sprucemymac-helper`.
- The LaunchDaemon property list lives at
  `Contents/Library/LaunchDaemons/com.van426326.sprucemymac.helper.plist` and
  uses `BundleProgram`, so relocation does not require an absolute app path.
- The helper listener derives the containing app's designated code-signing
  requirement and installs it with
  `NSXPCListener.setConnectionCodeSigningRequirement` before accepting XPC
  connections.
- The app derives the embedded helper's designated requirement and installs it
  with `NSXPCConnection.setCodeSigningRequirement` before activating the
  connection.
- Registration is offered only when the app is inside `/Applications` and the
  embedded executable and property list both exist.

Formal distribution builds that contain this LaunchDaemon must be signed with
the hardened runtime and notarized. An unsigned development build can compile,
run the nonprivileged UI, and execute the helper's inert self-test, but it is
not a valid installation artifact.

## Request protocol

The XPC protocol accepts exactly two strings: a task ID and a UUID request ID.
It accepts no file path, executable path, argument array, environment value, or
shell fragment. Requests run serially, and the helper remembers the most recent
128 UUIDs to reject replay.

Direct command-line invocation can only print the static `--self-test`
manifest. Every other argument exits with `EX_USAGE`; privileged maintenance is
reachable only through the signed XPC connection.

## Audited task catalog

| Task ID | Fixed executable and arguments | Timeout |
|---|---|---:|
| `flush-dns-cache` | `/usr/bin/dscacheutil -flushcache`; `/usr/bin/killall -HUP mDNSResponder` | 10 s each |
| `rebuild-spotlight-index` | `/usr/bin/mdutil -E /` | 30 s |

The command environment is replaced with a fixed minimal environment. Standard
input, output, and error are connected to `/dev/null`. A timed-out process is
terminated and, if necessary, killed after a bounded grace period. Any failed
step stops the task.

## Explicit exclusions

The helper does not accept arbitrary deletion targets, invoke a shell, run
Mole, execute `sudo`, purge memory, modify SIP, delete snapshots, change network
configuration, or install software. Adding a future task requires changing the
compiled catalog, its tests, this document, and the user-facing confirmation.

## Apple references

- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Updating your app package installer to use the new Service Management API](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
