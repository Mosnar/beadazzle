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

- Added customizable per-project sidebar bookmarks with searchable multi-select filters, nested boolean rules, consistent relative-date results, live previews, modified-bookmark Edit/Revert controls, custom names and icons, counts, editing, duplication, reordering, deletion, and recovery warnings for damaged saved data.
- Added actions to keep valid bookmarks recovered from damaged data or reset incompatible bookmark data, with every explicit reset archived separately for recovery.
- Fixed sidebar bookmarks so clicking their name or icon selects them like a native source-list row.
- Fixed selecting a bead in a filtered outline from revealing sibling beads that do not match the active filter.
- Fixed project switching so searches and filters from the previous project no longer carry into the next one.

## [1.1.0] - 2026-07-11

### Added

- Issue IDs in description, acceptance criteria, design, notes, and comments
  now link to their bead. Command-click links while editing; hovering an editor
  link shows the same bead preview used elsewhere in the app.
- The app menu now includes Project Settings beneath Settings when a project is open.
- Dependency counters now open relationship previews that explain each direction
  and link directly to the active blocker or blocked beads.
- Label counters now open a compact preview of the bead's labels.
- Project Storage settings can disable automatic snapshot exports for external
  Beads changes while keeping direct snapshot-file refreshes enabled.
- Beads blocked by a decision gate now show a banner in the detail view with
  inline Approve and Reject actions, so resolving the gate no longer requires
  opening it first.

### Changed

- Bead list display controls now live in the issue-list View Options menu and
  are remembered per project, while stale cut-off moved to Project Settings >
  Workflow.
- Comment bodies now load only when Activity is visible, keeping project loads
  lighter on trackers with long comment histories.
- Dependency icons and Relations headings now share the same Blocked by and
  Blocking symbols, and their counts include only the active relationships shown
  in the detail pane.
- Blocking relationships now use clear stop and raised-hand symbols instead of
  directional arrows. Child progress uses a nested-list symbol, and timer gates
  show a clock-badged blocked symbol where supported. Resolved timer gates drop
  the blocked styling and show a neutral timer symbol.
- External embedded-Dolt changes now trigger a coalesced background snapshot
  export and reload instead of waiting for the periodic JSONL export.
- Automatic snapshot refresh now catches changes made while Beadazzle was closed
  and keeps routine background catch-up from flashing a stale warning.
- Opening and refreshing large projects is faster: issue timestamps parse in a
  single pass, filter counts share the search scan with the visible list, and
  edits reuse the existing search index instead of rebuilding it.
- Sorting by title, status, or type is faster on large trackers, using a
  Finder-like natural order (case-insensitive, numeric-aware).
- New Bead, Open Beads Project, Refresh, and Find menu commands now target the
  focused window and disable when they don't apply, instead of broadcasting to
  every window.

### Fixed

- Adding a comment no longer risks crashing the app when `bd` rejects the
  bead before reading the comment body.
- A stalled `bd` write now times out with an error after two minutes instead of
  silently blocking every subsequent edit behind it.
- `bd` commands run from Finder/Dock launches now see the same search path used
  to locate `bd` itself, so helpers like git or dolt resolve in embedded projects.
- Checking for external changes no longer freezes the UI briefly when `bd` is
  holding a database lock mid-write.

- Local builds without Sparkle signing keys no longer show update controls that
  can offer the current release as if it were newer than the running build.
- Auto-update setup docs now point to the `public-release` GitHub environment.
- Deleting from a bead's context menu now uses the same confirmation as bulk
  deletion.
- Existing stale cut-off and bead-list display preferences carry forward when
  they are first migrated to per-project settings.
- Failed snapshot exports now leave the existing data visible with a stale
  warning, and malformed JSONL snapshots identify the failing line instead of
  silently hiding records.
- Interactive metadata previews can be pinned without closing when they were
  already opened by hovering, and relationship previews no longer focus their
  header by default.

## [1.0.0] - 2026-07-08

### Added

- Project settings now include a Storage pane that explains the active Beads
  backend, JSONL snapshot, sync model, hooks, and backup status.
- Project settings now show a pre-flight health check for bd, readable Beads
  data, snapshot freshness, export configuration, hooks, and backup status.
- Beadazzle now watches lightweight Beads export markers and warns when the
  readable JSONL snapshot may lag embedded Dolt, without polling the database.
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
- Changing a bead to Deferred now asks for an optional deferral date, while
  still supporting deferred beads with no date.

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

[Unreleased]: https://github.com/Mosnar/beadazzle/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Mosnar/beadazzle/releases/tag/v1.1.0
[1.0.0]: https://github.com/Mosnar/beadazzle/releases/tag/v1.0.0
[0.1.0-beta.1]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.1
[0.1.0-beta.2]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.2
[0.1.0-beta.3]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.3
