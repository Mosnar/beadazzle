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

- Automatic updates via Sparkle: the app checks for new builds in the
  background and presents a changelog with Install or Skip. A "Check for
  Updates…" menu item is available under the app menu.
- **Updates** settings pane with toggles for automatic update checks and for
  receiving beta (pre-release) builds.

## [0.1.0-beta.1]

### Added

- Initial public beta: native SwiftUI desktop client for Beads issue trackers,
  with a source-list sidebar, filterable/sortable issue list, and detail view.
- Reads from a populated `.beads/beads.db` with a JSONL fallback for embedded
  projects; all mutations route through the `bd` CLI.
- Signed and notarized DMG distribution.

[Unreleased]: https://github.com/Mosnar/beadazzle/compare/v0.1.0-beta.1...HEAD
[0.1.0-beta.1]: https://github.com/Mosnar/beadazzle/releases/tag/v0.1.0-beta.1
