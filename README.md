# Beadazzle

Beadazzle is a native macOS app for working with Beads issue trackers, especially repositories that use Beads in embedded mode.

The goal is a faster, more human-friendly desktop UI for large Beads projects: quick browsing, search, filtering, sorting, CRUD operations, dependency management, bulk actions, and type/status management without forcing users through a slow or awkward web UI.

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
- Project-local run script and Codex Run action.

## Requirements

- macOS 14 or newer.
- Xcode command line tools or Xcode with SwiftPM support.
- `bd` installed for write operations. Set `BEADAZZLE_BD_PATH` if `bd` is outside the app's launch environment `PATH`.
- A Beads project with a populated `.beads/beads.db` or `.beads/issues.jsonl`, `.beads/beads.jsonl`, or `.beads/beads.base.jsonl`.

## Run

From this repository:

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM executable, stages `dist/Beadazzle.app`, ad-hoc signs it, and launches it through LaunchServices.

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

The Codex app Run button is wired to the same script via `.codex/environments/environment.toml`.

## Build

```bash
swift build
```

Generated output lives under `.build/`, `.swiftpm/`, and `dist/`; those paths are ignored.

## Manual QA

Close reason dialog:

- Launch with `./script/build_and_run.sh --verify`.
- Open a Beads project, close one bead from the row context menu, and confirm the reason field is focused.
- Cancel the dialog and confirm the bead remains open.
- Close one bead with a blank reason and confirm the app refreshes without an error.
- Close one bead with a typed reason and confirm the app refreshes without an error.
- Select multiple beads, choose Bulk Actions > Close Selected..., enter a reason, and confirm all selected beads close.

## Architecture

- `Sources/Beadazzle/App`: app entrypoint and commands.
- `Sources/Beadazzle/Models`: Beads issue, dependency, draft, and sorting models.
- `Sources/Beadazzle/Stores`: app state, filtering, selection, and mutation coordination.
- `Sources/Beadazzle/Services`: source discovery, SQLite/JSONL snapshot reads, live source monitoring, `bd` command execution, and native panels.
- `Sources/Beadazzle/Views`: SwiftUI surfaces for sidebar, list, detail, editor, dependencies, and bulk actions.
- `Sources/Beadazzle/Support`: formatting, notifications, and visual styling helpers.

Reads are optimized for UI responsiveness: Beadazzle discovers one local source, loads a full snapshot off the main thread, builds an immutable project index, and keeps views querying that in-memory index. Writes go through `bd` instead of direct database mutation so Beads semantics, hooks, history, and validation remain intact.

## Notes

This is an early native client. High-value next slices include custom type configuration editing, richer dependency graph visualization, table-style views for very large trackers, and stronger write-result/error presentation.
