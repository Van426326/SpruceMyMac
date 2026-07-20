# Security policy

SpruceMyMac handles filesystem cleanup and ships a restricted privileged
helper, so security reports are treated as high priority.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could cause unintended
deletion, privilege escalation, signature bypass, path traversal, or exposure
of private filesystem data. Use GitHub's private vulnerability reporting for
the repository. Include the affected version, macOS version, reproduction
steps, expected behavior, and the smallest safe proof of concept.

Never include credentials, unrelated personal files, or destructive payloads.

## Supported versions

Until the first stable release, only the latest published version is supported.
Security fixes will be documented in the changelog and release notes.

The privileged-helper threat model and fixed task catalog are documented in
[`Helper/SECURITY.md`](Helper/SECURITY.md).
