# Beadazzle Agent Notes

Beadazzle is a SwiftPM native macOS app. Prefer small, focused SwiftUI files and keep the current sidebar-list-detail desktop structure.

## Build and Run

- Build with `rtk swift build`.
- Launch with `rtk ./script/build_and_run.sh`.
- Verify launch with `rtk ./script/build_and_run.sh --verify`.
- The Codex Run action points at `./script/build_and_run.sh`.

## Xcode MCP and Warnings

- When the user mentions Xcode warnings or asks to use Xcode, use the Xcode MCP server first.
- If the MCP asks for a tab identifier, call an Xcode MCP tool and use the open Beadazzle workspace tab it reports.
- Use `BuildProject` to reproduce Xcode build diagnostics, then `GetBuildLog` with `severity: "warning"` to confirm the build log is warning-free.
- Use `XcodeListNavigatorIssues` with `severity: "warning"` to inspect warnings visible in Xcode's Issue Navigator.
- For warnings tied to specific files, use `XcodeRefreshCodeIssuesInFile` on the affected source files after edits.
- Do not stop at a successful shell build when Xcode reported warnings; verify through Xcode MCP that there are no current warnings or explain any stale runtime entries that remain in the navigator.

## Changelog

- Record user-facing changes in `CHANGELOG.md` under `## [Unreleased]` as part of the work that makes them — new features, behavior changes, notable fixes. Skip internal-only churn (refactors, test-only edits, CI plumbing) that a user would never notice.
- Write entries for users of the app, not as commit summaries. The release workflow reads the tag's section for both the GitHub release notes and the in-app Sparkle update dialog, and a release fails if its section is missing. See `docs/AUTO_UPDATES.md`.

## Project Boundaries

- Do not edit generated output in `.build/`, `.swiftpm/`, or `dist/`.
- Keep `script/build_and_run.sh` as the single local build/run entrypoint.
- Keep `.codex/environments/environment.toml` separate from app source.
- Use SwiftUI first. Use AppKit interop only for narrow platform edges such as panels or window behavior.

## Beads Data Model

- Read issues quickly from `.beads/beads.db` when populated.
- Fall back to `.beads/issues.jsonl` for embedded projects whose SQLite `issues` table is empty.
- Do not write directly to Beads internals unless the user explicitly asks for a low-level repair.
- Route creates, updates, deletes, close actions, bulk changes, and dependency changes through the `bd` CLI.

## UI Direction

- Preserve native macOS source-list behavior in the sidebar.
- Keep filters in the sidebar and list-specific controls, such as sorting, near the issue list.
- Favor compact, stable metadata over wrapped badges or card-heavy layouts.
- Keep selection changes and search responsive; avoid disk reads on simple navigation.
