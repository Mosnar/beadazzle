# Security Policy

## Supported Versions

Security fixes are handled on a best-effort basis for:

- the current `main` branch,
- and the most recent public beta release tag.

Older beta builds may not receive backported fixes.

## Reporting a Vulnerability

Please do not open a public GitHub issue for a suspected security problem.

Instead, report it privately to:

- `ransom@venveo.com`

Please include:

- the affected Beadazzle version or commit,
- your macOS version,
- reproduction steps,
- expected versus actual behavior,
- and any proof-of-concept material that helps confirm impact.

If the issue involves sensitive repository data, redact private issue contents when possible and note any redactions you made.

## Response Expectations

Reports will be triaged as quickly as possible. After confirmation, Beadazzle will aim to:

- acknowledge receipt,
- reproduce and scope the issue,
- prepare a fix or mitigation,
- and publish a coordinated release note once it is safe to do so.

## Operational Notes

Beadazzle is a local desktop client. It reads Beads data from local repositories and routes write operations through the local `bd` CLI. It does not enable remote telemetry or analytics by default.