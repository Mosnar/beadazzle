# Manual QA

Run the automated baseline first:

```bash
swift build
swift test
./script/test_release_common.sh
python3 -m unittest script/test_validate_appcast.py
```

Use a disposable Beads project for workflows that create, close, delete, sync, or
reconfigure beads. Launch the staged app with:

```bash
./script/build_and_run.sh --verify
```

## Workspace and window lifecycle

- Open two projects in separate windows. Confirm each window keeps its own selection,
  filters, outline expansion, and detail page while switching between them.
- Try to open a project that is already open. Confirm Beadazzle raises its existing
  window instead of creating a duplicate.
- Edit a bead and immediately close its window. Reopen the project and confirm the edit
  is present in both the issue list and detail view.
- Repeat the immediate-close check from a worktree or routed project. Confirm
  `bd context --json` reports the same tracker directory Beadazzle shows in Project
  Settings, and that the reopened window contains the edit.
- Close a window while two mutations are queued. Reopen the project immediately and
  confirm the new window waits for both writes and the final readable snapshot.
- Quit and relaunch with multiple project windows open. Confirm each surviving project
  is restored once and a deleted project folder falls back without duplicating another
  open project.

## Snapshot and refresh behavior

- Run a manual refresh after an external `bd` edit. Confirm the edit appears and the
  snapshot freshness state returns to current.
- Temporarily make snapshot export fail in a disposable environment, then refresh.
  Confirm the last readable issue list remains visible with a clear stale-snapshot
  warning; restore export access and confirm Refresh clears it.
- For a server or shared-server project, activate the app after an external edit and
  confirm the refreshed snapshot is loaded without polling while the app is idle.

## Sync and project modes

- Smoke-test one embedded, server, and shared-server project. Confirm each resolves the
  expected tracker path and unsupported/no-remote states remain usable.
- For a configured embedded remote, run Pull, Push, and combined Sync. Confirm Sync pulls
  before pushing, a failed pull suppresses push, and successful pull/sync reloads issues.
- Confirm lightweight remote-change checks never modify the database or replace explicit
  Pull and Sync actions.

## Close reason dialog

- Close one bead from the row context menu and confirm the reason field is focused.
- Cancel and confirm the bead remains open.
- Close with a blank reason, then with a typed reason, and confirm both refresh cleanly.
- Select multiple beads, choose **Bulk Actions > Close Selected…**, enter a reason, and
  confirm all selected beads close.

## Draft recovery and destructive actions

- Change an existing bead's title and body without saving, navigate to another bead,
  then return. Confirm the draft is intact and Revert clears it.
- Repeat with an unfinished comment, switch projects, close the window, and reopen the
  project. Confirm both kinds of draft return and the window's edited indicator clears
  only after saving or reverting bead edits and posting or clearing comment text.
- Force a comment command to fail in a disposable project. Confirm the typed comment
  remains editable and Try Again can post it without retyping.
- Delete a parent with descendants. Confirm the sheet lists every selected bead and
  descendant by ID and title, and that cancelling changes nothing.

## Accessibility and display comfort

- In Settings ▸ Display, switch among Compact, Comfortable, and Large row density while
  scrolling and changing selection. Confirm rows stay aligned and responsive.
- Narrow the detail pane until metadata overflows. Confirm the horizontal affordance is
  visible and every metadata control remains reachable by scrolling and keyboard.
- Enable Reduce Motion in System Settings, then exercise project Sync status, folder
  automation results, bead-picker keyboard navigation, and About email copying. Confirm
  content updates without sliding or animated scrolling.
- With VoiceOver, traverse the project picker, empty-state actions, Activity refresh and
  comment controls, and delete preview. Confirm every icon-only action has a useful name
  and the delete groups expose their counts and bead titles.

## Release smoke check

- Run `./script/build_and_run.sh --verify` from a clean checkout.
- Open Settings, Project Settings, About, Acknowledgments, and License windows.
- Confirm Check for Updates opens normally and the app can be quit and relaunched without
  losing workspace restoration state.
