# Changelog

All notable changes to Beadazzle are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries under **Unreleased** ship in the next tagged build. When cutting a
release, rename the heading to the version and date, then start a fresh
**Unreleased** section. The release workflow reads the section matching the tag
for both the GitHub release notes and the in-app update dialog, so write these
for users, not for the commit log.

## [Unreleased]

### Added

- Project settings now include a Ready workflow preference that can hide parent
  beads when all unfinished child beads are blocked.
- Relationship fields now use a fast bead picker with search, filters, outline
  mode, and a compact quick-create flow for parent, blocking, and sub-issue
  workflows.
- Blocked rows now explain why each bead is blocked inline, including active
  blocker beads, gates, external references, resolved gates, and manually
  blocked beads with no active blocker.
- Blocked bead detail pages now show an inline helper for stale blocked states,
  and sub-issue rows surface the same blocker context as the main list.

### Changed

- The Gates screen now acts as a dedicated gate queue: filters and sort controls
  are hidden, actionable gates are grouped at the top with an accent outline,
  ready gates use a green Ready label, and pending gates continue below them.

### Fixed

- Blocked epic helpers no longer offer gate-creation actions that the current
  Beads CLI cannot complete.
- Blocker relationship pickers and quick-create now respect Beads' epic-only
  blocking rule instead of offering relationships that fail after selection.
- Status change menus no longer show the status already set on the selected
  bead.
- Selecting beads in the Gates list now keeps the active row highlight aligned
  with AppKit selection, including during fast keyboard navigation.
- Blocked parent and context rows now recognize blocked sub-issues before
  showing the "no active blocker" helper.
- Bead picker quick-create labels now use the same label picker as the rest of
  the app, label filters are searchable, and picker popovers use native
  material/glass styling instead of a heavy gradient panel, with tighter form
  spacing and smoother expansion.
- Changing bead metadata from the detail pane now updates the app immediately
  while the write runs in the background; only title and body text remain
  draft-until-save.
- Opening a folder before Beads is initialized now keeps the project selector
  visible, labels the project as needing setup, and keeps the init controls
  usable in narrower windows.

## [0.1.0-beta.3] - 2026-07-07

### Changed

- Bead detail pages now separate blocking relationships into the Properties
  sidebar and show child beads in a dedicated Sub-issues list with instant
  parent-aware creation. Gate blockers get dedicated rows with gate type,
  timer remaining, and gate-specific hover details. Sidebar relationships now
  show only active blockers, and hover previews stay open while hovered with
  the same click-to-copy bead ID affordance used in the main bead list.
- Child bead detail pages now show a clickable parent bead ID in breadcrumbs,
  Properties, and compact metadata when a parent exists.
- Closed beads now show Reopen instead of Close in action menus.
- Closed beads no longer show Create Gate until they are reopened.
- Human gates now use Approve and Reject actions, and approving a gate moves
  eligible blocked beads back to open when no other blockers remain.
- Closing a bead that still has open child beads now asks whether to close the
  children too and shows the child beads that will be closed.
- Selecting a bead now opens its detail beside the list without auto-collapsing
  the list by window width; double-click a bead to open it full-page, with
  Back/Forward support for returning to the split view.
- Edits, closes, deletes, priority/type changes, and dependency changes now
  apply **instantly** with no loading spinner. The change appears the moment you
  make it while the write is saved in the background; if the write fails, the
  change is rolled back and an error is shown. Previously changes could take up
  to several minutes to appear (and manual Refresh didn't help) on repos backed
  by an embedded database, because the app was reading a snapshot that database
  only refreshed periodically.

### Fixed

- Normal bead creation and type-changing controls no longer offer or accept
  the Gate type; gates are created from an existing bead instead.
- Gate beads now stay out of the Ready list and remain in the Gates section.
- Project loading now recovers instead of spinning forever when a `bd` metadata
  read or snapshot export gets stuck waiting on an embedded-database lock, and
  snapshot exports now preserve the previous readable snapshot if they fail.
- Closing parent beads with confirmed child beads now uses a single ordered
  `bd` write where possible, reducing the chance of partially applied closes.
- Parent beads can no longer be closed while child beads remain unresolved
  through status changes, detail saves, gate rejection, or relationship edits.
- Parent-child links now also reject attaching an unresolved child tree under a
  done parent.
- Project switcher rows now respond across the full highlighted row instead of
  only on the project name text.
- Right-clicking an unselected bead now focuses it for the context menu without
  opening its detail, so actions apply to the focused bead without navigating.
- Right-clicked beads now show a subtle gray focus outline while their context
  menu is targeted.
- Fixed a runaway loop that pinned the CPU, hammered the disk, and slowly grew
  memory the entire time a project was open — even while the app sat idle. The
  app's own background reads were tripping its file-change watcher, which kicked
  off another read, and so on without end. Watching is now limited to real
  content changes, and routine reloads no longer re-run `bd` for status/type
  definitions that haven't changed, so an idle window now uses effectively no CPU.
- Manual Refresh and background reconciliation now re-read current state on
  embedded-database repos, so the list always converges to what `bd` actually
  recorded.

## [0.1.0-beta.2] - 2026-07-06

### Added

- Automatic updates via Sparkle: the app checks for new builds in the
  background and presents a changelog with Install or Skip. A "Check for
  Updates…" menu item is available under the app menu.
- **Updates** settings pane with toggles for automatic update checks and for
  receiving beta (pre-release) builds.

## [0.1.0-beta.1] - 2026-07-06

### Added

- Initial public beta: native SwiftUI desktop client for Beads issue trackers,
  with a source-list sidebar, filterable/sortable issue list, and detail view.
- Reads from a populated `.beads/beads.db` with a JSONL fallback for embedded
  projects; all mutations route through the `bd` CLI.
- Signed and notarized DMG distribution.

[Unreleased]: https://github.com/Mosnar/beadazzle/compare/v0.1.0-beta.3...HEAD
[0.1.0-beta.1]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.1
[0.1.0-beta.2]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.2
[0.1.0-beta.3]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.3
