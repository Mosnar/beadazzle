# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Beadazzle is a native macOS SwiftUI app (SwiftPM, macOS 14+) that provides a fast desktop UI for [Beads](https://github.com/) issue trackers, especially repos using Beads in embedded mode. See `README.md` for the feature list and `AGENTS.md` for repo boundaries.

## Commands

```bash
swift build                        # Build the executable target
swift test                         # Run the full test suite
swift test --filter BeadStoreOutlineExpansionTests   # Run one test class (or ...Tests/testMethod)
./script/build_and_run.sh          # Build, stage dist/Beadazzle.app, ad-hoc sign, launch via LaunchServices
./script/build_and_run.sh --verify # Launch and confirm the process stays up (used for smoke checks)
./script/build_and_run.sh --logs   # Launch + stream os_log for the process
```

`build_and_run.sh` is the single build/run entrypoint — do not add alternate launch paths. Generated output (`.build/`, `.swiftpm/`, `dist/`) is gitignored; never edit it. Keep `.codex/environments/environment.toml` separate from app source.

## Architecture

The read and write paths are deliberately separate:

**Reads (snapshot → immutable index → in-memory queries).** `BeadProjectLoader.loadProject` reads one local data source off the main thread and builds an immutable `BeadProjectIndex`; views query that in-memory index rather than hitting disk on navigation. Source resolution order (`BeadsSnapshotReader` / `BeadsDataSourceDiscovery`): a populated SQLite `.beads/beads.db` first, then a JSONL fallback (`issues.jsonl` / `beads.jsonl` / `beads.base.jsonl`) — used for embedded projects whose SQLite `issues` table is empty. `BeadsDataSourceMonitor` watches the source for local changes and triggers live reloads.

**Writes (always through the `bd` CLI).** All mutations — create, update, close, delete, bulk update, dependency add/remove, comments, custom status/type definitions — route through `BeadsCommandService` (conforms to `BeadsCommanding`), which shells out to `bd`. Never write to `.beads/beads.db` or the JSONL files directly; going through `bd` preserves Beads semantics, hooks, history, and validation. `BeadsCLI.executable()` resolves the `bd` binary: configured pref path → `BEADAZZLE_BD_PATH` env → `PATH` → common fallback dirs (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). After writes, `BeadsCommandService` re-exports a readable JSONL snapshot so the next read reflects the change.

**State: `BeadStore` (`Sources/Beadazzle/Stores/`).** A single `@Observable @MainActor` object holding essentially all UI state — project readiness, issues, filter/sort/selection state, dependencies, comments, preferences. It is the central hub; most views take it via `.environment(store)`. Note the pattern: filter/sort/preference properties use `didSet` observers that call `filterStateDidChange` / `sortStateDidChange` / rebuild methods and persist to `UserDefaults`. When adding UI state, follow that pattern rather than scattering derived recomputation. `BeadIssueListQuery` handles filtering/sorting into the displayed row list.

**App wiring (`Sources/Beadazzle/App/BeadazzleApp.swift`).** Menu commands reach the key window via focused scene values: `ContentView` publishes `WorkspaceCommandActions` with `.focusedSceneValue` and the `WorkspaceCommands`/`BeadSaveCommands` command groups consume them (`Support/WorkspaceCommands.swift`, `Support/BeadSaveCommands.swift`), so commands scope to the focused scene and disable when no window provides them. The app has three scenes: main window, Settings, and a `URL`-parameterized Project Settings window.

**Directory roles:** `Models/` (data types), `Stores/` (state + query logic), `Services/` (source discovery, snapshot readers, monitor, `bd` execution, native panels), `Views/` (SwiftUI surfaces), `Support/` (formatters, notifications, visual style, menu commands).

## Conventions

- SwiftUI first; use AppKit interop only for narrow platform edges (panels, window behavior). Keep files small and focused.
- Preserve native macOS source-list behavior in the sidebar. Keep filters in the sidebar and list-specific controls (e.g. sorting) near the issue list. Favor compact, stable metadata over wrapped badges or card-heavy layouts.
- Keep navigation/search responsive — avoid disk reads on simple selection; that's what the in-memory index is for.
- Record user-facing changes in `CHANGELOG.md` under `## [Unreleased]` as you make them (features, behavior changes, notable fixes) — written for users, not as commit summaries. Skip internal-only churn a user wouldn't notice. The release workflow reads the tag's section for the GitHub release notes and the in-app Sparkle update dialog, and fails if it's missing; see `docs/AUTO_UPDATES.md`.

## Xcode warnings

When the user mentions Xcode warnings, use the Xcode MCP server (not just a shell build): `BuildProject` to reproduce, `GetBuildLog` with `severity: "warning"`, `XcodeListNavigatorIssues`, and `XcodeRefreshCodeIssuesInFile` on edited files. A clean `swift build` does not prove Xcode is warning-free.
