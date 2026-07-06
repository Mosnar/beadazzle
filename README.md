# Beadazzle

Beadazzle is a native macOS app for working with Beads issue trackers, especially repositories that use Beads in embedded mode.

The goal is a faster, more human-friendly desktop UI for large Beads projects: quick browsing, search, filtering, sorting, CRUD operations, dependency management, bulk actions, and type/status management without forcing users through a slow or awkward web UI.

Beadazzle is now set up for public beta distribution through GitHub Releases, including a signed and notarized macOS `.dmg` release path.

## Public Beta Install

1. Download the latest `Beadazzle-<version>.dmg` from [GitHub Releases](../../releases).
2. Open the disk image and drag `Beadazzle.app` into `/Applications`.
3. Launch the app and open a local repository that contains Beads data.

The published DMG is intended to be `Developer ID` signed, notarized, and stapled. If you are running a local ad-hoc build instead of a release artifact, Gatekeeper validation will not pass.

## Current Features

- Native macOS SwiftUI app with a sidebar, issue list, and detail pane.
- Opens a repository containing a populated `.beads/beads.db` or a supported Beads JSONL source.
- Reopens the last selected Beads project when available.
- Fast issue browsing with search, filters, sort menu, and multi-selection.
- Detail view for description, design, acceptance criteria, notes, labels, dependencies, and metadata.
- CRUD and bulk actions routed through the `bd` CLI.
- Dependency add/remove plus clickable related beads.
- Source-oriented snapshot reads: populated SQLite first, then JSONL fallback.
- Live reload for local Beads source changes.
- Local app-bundle and DMG packaging scripts plus GitHub release automation.

## Requirements

- macOS 14 or newer.
- Xcode command line tools or Xcode with SwiftPM support.
- `bd` installed for write operations. Set `BEADAZZLE_BD_PATH` if `bd` is outside the app's launch-environment `PATH`.
- A Beads project with either:
  - a populated `.beads/beads.db`, or
  - `.beads/issues.jsonl`, `.beads/beads.jsonl`, or `.beads/beads.base.jsonl`.

## Build, Test, and Run

Repo-local `rtk` commands are the preferred entrypoints in this project:

```bash
rtk swift build
rtk swift test
rtk ./script/build_and_run.sh
```

Useful launch modes:

```bash
rtk ./script/build_and_run.sh --verify
rtk ./script/build_and_run.sh --logs
rtk ./script/build_and_run.sh --telemetry
rtk ./script/build_and_run.sh --debug
```

If you are not using `rtk`, the equivalent raw commands are `swift build`, `swift test`, and `./script/build_and_run.sh`.

`script/build_and_run.sh` remains the single local build/run entrypoint. It builds the SwiftPM executable, stages `dist/Beadazzle.app`, applies an ad-hoc signature for local launch, and opens the app through LaunchServices.

Generated output lives under `.build/`, `.swiftpm/`, and `dist/`; those paths are ignored and should not be edited manually.

## Release Packaging

Local release helpers live under `script/`:

```bash
./script/test_release_common.sh
./script/build_app_bundle.sh --release-tag v0.1.0-beta.1 --build-number 100
./script/create_release_dmg.sh --release-tag v0.1.0-beta.1 --build-number 100
```

- `build_app_bundle.sh` assembles `dist/Beadazzle.app` with tag-derived bundle metadata.
- `create_release_dmg.sh` builds `dist/Beadazzle-<version>.dmg` plus a `.sha256` checksum and verifies the mounted image contents.
- `notarize_release.sh` submits the signed app bundle or DMG to Apple, staples the result, re-validates Gatekeeper checks, and refreshes the DMG checksum after stapling.
- `.github/workflows/release.yml` runs the same scripts for tag pushes or manual release dispatches.

See [`docs/releasing.md`](docs/releasing.md) for the maintainer release checklist and required GitHub secrets.

## Data Access, Writes, and Privacy

Beadazzle is designed around local repository data.

- Reads come from one local Beads source at a time: a populated `.beads/beads.db` first, then a JSONL fallback when needed.
- When the app needs a readable snapshot after a mutation, it asks `bd` to export one and then reloads that local snapshot.
- Create, update, close, delete, dependency, comment, gate, and workflow-definition changes go through the `bd` CLI. Beadazzle does not write directly to `.beads/beads.db` or Beads JSONL files.
- Beadazzle does not ship with `bd`; you must install it separately for write actions.
- The app does not enable remote telemetry, analytics, or crash reporting by default.
- Optional diagnostics are local-only: `--logs` and `--telemetry` stream macOS unified logs on your machine, and the performance signposts are only visible if you intentionally inspect them with Apple developer tools.

## Governance and Policies

- [License](LICENSE)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Third-Party Notices](THIRD_PARTY_NOTICES.md)
- [Maintainer Release Guide](docs/releasing.md)

## Manual QA

Close reason dialog:

- Launch with `rtk ./script/build_and_run.sh --verify`.
- Open a Beads project, close one bead from the row context menu, and confirm the reason field is focused.
- Cancel the dialog and confirm the bead remains open.
- Close one bead with a blank reason and confirm the app refreshes without an error.
- Close one bead with a typed reason and confirm the app refreshes without an error.
- Select multiple beads, choose `Bulk Actions > Close Selected...`, enter a reason, and confirm all selected beads close.

## Architecture

- `Sources/Beadazzle/App`: app entrypoint and commands.
- `Sources/Beadazzle/Models`: Beads issue, dependency, draft, and sorting models.
- `Sources/Beadazzle/Stores`: app state, filtering, selection, history, and mutation coordination.
- `Sources/Beadazzle/Services`: source discovery, SQLite/JSONL snapshot reads, live source monitoring, `bd` command execution, and native panels.
- `Sources/Beadazzle/Views`: SwiftUI surfaces for sidebar, list, detail, editor, dependencies, and bulk actions.
- `Sources/Beadazzle/Support`: formatting, notifications, performance signposts, and visual styling helpers.

Reads are optimized for UI responsiveness: Beadazzle discovers one local source, loads a full snapshot off the main thread, builds an immutable project index, and keeps views querying that in-memory index. Writes go through `bd` instead of direct database mutation so Beads semantics, hooks, history, and validation remain intact.
