# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Beadazzle is a native macOS SwiftUI app (SwiftPM, macOS 14+) that provides a fast desktop UI for [Beads](https://github.com/gastownhall/beads) issue trackers, especially repos using Beads in embedded mode. See `README.md` for the feature list and `AGENTS.md` for repo boundaries.

## Commands

```bash
swift build                            # Build the executable target
swift test                             # Run the full test suite
swift test --filter BeadStoreOutlineExpansionTests   # Run one test class (or ...Tests/testMethod)
./script/build_and_run.sh              # Build, stage dist/Beadazzle.app, ad-hoc sign, launch via LaunchServices
./script/build_and_run.sh --verify     # Launch and confirm the process stays up (used for smoke checks)
./script/build_and_run.sh --logs       # Launch + stream os_log for the process
./script/build_and_run.sh --telemetry  # Launch + stream only the app's own subsystem
./script/build_and_run.sh --debug      # Launch the staged binary under lldb
```

`build_and_run.sh` is the single build/run entrypoint — do not add alternate launch paths. Generated output (`.build/`, `.swiftpm/`, `dist/`) is gitignored; never edit it. Keep `.codex/environments/environment.toml` separate from app source.

## Architecture

The read and write paths are deliberately separate:

**Project environment (resolved first, cached).** `BeadProjectLoader.resolveEnvironment` asks `bd context --json` and builds a `BeadsProjectEnvironment`. Only current Dolt-backed projects are supported: a non-`dolt` backend or an unrecognized Dolt mode throws `BeadError.unsupportedProjectMode`; recognized modes are embedded, server, and shared-server. The environment also carries the effective tracker directory, so worktree redirects and explicitly routed `.beads` paths read the same source `bd` writes. It is resolved once per open and reused by routine reloads, so navigation never re-spawns capability probes.

**Reads (JSONL snapshot → immutable index → in-memory queries).** `BeadsDataSourceDiscovery` looks only for a JSONL snapshot in the tracker directory (`issues.jsonl` / `beads.jsonl` / `beads.base.jsonl`) — there is no SQLite read path; legacy `.beads/beads.db` projects are intentionally unsupported. `BeadProjectLoader` reads that snapshot off the main thread and builds an immutable `BeadProjectIndex`; views query that index rather than hitting disk on navigation. Beadazzle produces the snapshot itself rather than requiring `bd` auto-export: `exportAndLoadProject` runs `bd export` when no snapshot exists (`BeadStore+Project.swift` recovers from `projectMissingDataSource` this way), `refreshSnapshotAndLoadProject` re-exports before post-mutation reconciles and manual refreshes, and server/shared-server projects also export on open and app activation. `BeadsDataSourceMonitor` watches the snapshot with `DispatchSource` file-system events — no polling of idle projects — and triggers live reloads.

**Writes (always through the `bd` CLI).** All mutations — create, update, close, delete, bulk update, dependency add/remove, comments, gates, custom status/type definitions, Dolt pull/push — route through `BeadsCommandService` (conforms to `BeadsCommanding`), which shells out to `bd`. Never write to Dolt tables or the JSONL snapshot directly; going through `bd` preserves Beads semantics, hooks, history, and validation. `BeadMutationWriteQueue` serializes those writes so optimistic UI state can be applied immediately without reordering `bd` invocations, and a failed write does not poison the queue. `BeadsCLI.executable()` resolves the `bd` binary: configured pref path → `BEADAZZLE_BD_PATH` env → `PATH` (searched together with fallback dirs `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) → `/usr/bin/env bd`. `exportReadableSnapshot` writes `bd export` output to a temp file, validates it, and atomically installs it as the tracker directory's `issues.jsonl`, so the next read reflects the change.

**Remote synchronization and freshness.** `BeadStore+ProjectHealth.swift` owns explicit Pull, Push, and combined Sync. Sync serializes `bd dolt pull` followed by `bd dolt push`, then exports and reloads the readable snapshot; a pull failure suppresses push, while a push failure still reconciles successfully pulled data. `BeadStore+DoltRemoteFreshness.swift` separately performs a read-only Git `ls-remote` probe for `refs/dolt/data`. It never pulls or mutates the database. Automatic probes require an active workspace scene, the app preference, embedded mode, a compatible Git-backed remote, and a machine-local checkpoint established after a successful Beadazzle remote action. The monitor re-resolves the current remote and checkpoint each iteration and exits when eligibility changes. `CancellableProcessRunner` is the cancellation-aware, bounded-output seam for read-only subprocesses; commands with stdin retain `BeadsCommandService`'s exit-status-aware write path. See `docs/BEADS_SYNC.md` for the user-facing model.

**State: `BeadStore` (`Sources/Beadazzle/Stores/`).** `BeadStore` is the `@Observable @MainActor` composition root and the single dependency views need; install it with `.beadStoreEnvironment(store)` (`Support/BeadStoreEnvironment.swift`), not a bare `.environment`. It owns narrower observable domains — `BeadProjectStore` (readiness, index, environment), `BeadWorkspaceStore` (filters, sort, selection, outline), `BeadDetailStore`, and the separately housed `BeadMutationStore` (optimistic metadata state) — and its behavior is split across ~20 `BeadStore+*.swift` extensions by concern (Project, WorkspaceQuery, Mutations, Folders, Gates, Semantics, ProjectHealth, …). Put new work in the matching focused file rather than growing `BeadStore.swift`.

Note the state pattern: filter/sort/preference properties use `didSet` observers that guard on `oldValue`, then call `filterStateDidChange` (with `debounce: true` for search text) / `sortStateDidChange` / rebuild methods, persist to `UserDefaults`, and sync the per-project workspace snapshot. When adding UI state, follow that pattern rather than scattering derived recomputation.

The query pipeline runs off the main actor: `BeadStore+WorkspaceQuery.swift` hands recompute requests to detached workers that call `BeadIssueListQuery` (filter/sort into the displayed row list) and evaluate saved-view predicates through `CompiledBeadFilter`, an immutable precompiled form of a `BeadFilterGroup`. Keep filtering and sorting out of view bodies so large projects stay responsive.

**App wiring (`Sources/Beadazzle/App/BeadazzleApp.swift`).** Menu commands reach the key window via focused scene values: `ContentView` publishes `WorkspaceCommandActions` and `BeadNavigationCommandContext` with `.focusedSceneValue` and the command groups in `Support/` consume them — `WorkspaceCommands`, `BeadSaveCommands`, `AppSettingsCommands`, `ProjectSettingsCommands`, `BeadNavigationMenuItems` — so commands scope to the focused scene and disable when no window provides them. The app declares six scenes: the main workspace `WindowGroup`; About, Acknowledgments, License, and Settings `Window` scenes; and a `URL`-parameterized Project Settings `WindowGroup`.

**Multiple workspace windows.** Each workspace window owns its own `BeadStore` — a store is bound to one project (index, write queue, snapshot monitor, optimistic state), so a second project needs a second store. `BeadWorkspaceWindowRegistry` (`Stores/`) owns them, keyed by the `BeadWorkspaceWindowRequest` the main `WindowGroup` presents; `WorkspaceWindowRoot` resolves the store, reports its `NSWindow` back, and releases the window on close. Route every project open through `registry.openProject(_:from:destination:)` rather than calling `store.openProject` from a view: it honors the `Open projects in` preference, the explicit new-window commands, and brings forward the window already showing a project instead of opening it twice. Exclusivity is ultimately by resolved tracker identity, not project path — distinct roots can route to one tracker (worktrees, configured Beads directories), so the registry repairs duplicate bindings when `bd context` resolves, and a closed window's store keeps its tracker reserved until its queued writes drain. `store(for:)` deliberately creates an empty store — SwiftUI evaluates window bodies freely, so project loading belongs in `prepareWindow(_:)` from `onAppear`, never in a body. Teardown hangs off `NSWindow.willCloseNotification` (delivered synchronously so state flushes while the window still exists) with `onDisappear` as a second path; `releaseWindow` is idempotent for that reason. Views that need to know which projects are open elsewhere ask `isProjectOpenInAnotherWindow(_:from:)` and observe `windowCompositionRevision`, since the live-window set is otherwise plain storage. App-wide state (the app preferences and the recents list) lives in `UserDefaults`; when one store persists it, `BeadAppStateBroadcasting` tells the others to re-read it, so add new app-scoped preferences to `reloadAppPreferences()`. Auxiliary scenes get their store from the registry — `auxiliaryStore()` for Settings, `store(forProject:)` for Project Settings.

**Directory roles:** `Models/` (data types), `Stores/` (state + query logic), `Services/` (source discovery, snapshot readers, monitors, `bd` execution, cancellable subprocesses, remote probes, native panels), `Views/` (SwiftUI surfaces), `Support/` (formatters, visual style, menu commands, drag-and-drop, workspace history, performance signposts).

## Conventions

- SwiftUI first; use AppKit interop only for narrow platform edges (panels, window behavior). Keep files small and focused.
- Preserve native macOS source-list behavior in the sidebar. Keep filters and list-specific controls together in the window toolbar while the issue list is visible. Favor compact, stable metadata over wrapped badges or card-heavy layouts.
- Keep navigation/search responsive — avoid disk reads on simple selection; that's what the in-memory index is for.
- Record user-facing changes in `CHANGELOG.md` under `## [Unreleased]` as you make them (features, behavior changes, notable fixes) — written for users, not as commit summaries. Skip internal-only churn a user wouldn't notice. The release workflow reads the tag's section for the GitHub release notes and the in-app Sparkle update dialog, and fails if it's missing; see `docs/AUTO_UPDATES.md`.

## Xcode warnings

When the user mentions Xcode warnings, use the Xcode MCP server (not just a shell build): `BuildProject` to reproduce, `GetBuildLog` with `severity: "warning"`, `XcodeListNavigatorIssues`, and `XcodeRefreshCodeIssuesInFile` on edited files. A clean `swift build` does not prove Xcode is warning-free.
