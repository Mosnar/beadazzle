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

### Changed

- Edits, closes, deletes, priority/type changes, and dependency changes now
  apply **instantly** with no loading spinner. The change appears the moment you
  make it while the write is saved in the background; if the write fails, the
  change is rolled back and an error is shown. Previously changes could take up
  to several minutes to appear (and manual Refresh didn't help) on repos backed
  by an embedded database, because the app was reading a snapshot that database
  only refreshed periodically.

### Fixed

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

[Unreleased]: https://github.com/Mosnar/beadazzle/compare/v0.1.0-beta.2...HEAD
[0.1.0-beta.1]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.1
[0.1.0-beta.2]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.2
