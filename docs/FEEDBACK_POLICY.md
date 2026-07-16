# Mutation feedback policy

Beadazzle performs many live writes (metadata edits, relationship changes, creation,
close/delete, bulk updates) and every write routes through the `bd` CLI. This document
defines one consistent model for how those writes report progress, success, and failure,
so rapid interaction feels immediate without ever hiding a real failure.

The implementation lives in `Stores/BeadStore+Feedback.swift`, the `BeadMutationFailure`
model, and the `MutationErrorDialog` view.

## Dispositions

Every mutation surface follows one of four dispositions.

### 1. Quiet success (the default)

Optimistic writes apply to the in-memory index immediately and show **no banner or
confirmation** — the change is simply there. Do not add success toasts for routine edits.

For *meaningful* completions — create, delete, close, and relationship (parent / dependency)
changes — post a VoiceOver announcement via `announceCompletion(_:)` so assistive-technology
users get the same confirmation sighted users get from seeing the change. Routine field edits
(assignee, labels, dates, status/priority) stay silent even to VoiceOver.

### 2. Deferred local progress

Optimistic writes are invisible when fast. A local progress indicator appears **only when a
write outlives the perceptible-latency threshold** (~500 ms), and only near the affected
content (the metadata ribbon shows a small spinner for that bead). It never disables or
freezes unrelated navigation, and never appears as a global overlay.

Tracked with `beginPerceptibleBusy(issueIDs:)` / `endPerceptibleBusy(_:)` and read by views
through `isPerceptiblyBusy(issueID:)`.

### 3. Standardized error dialog

Any `bd` / command failure surfaces through **one** dialog (`MutationErrorDialog`), presented
as a sheet driven by `sheet(item:)` on the failure's identity — queued failures present one
after another deterministically. Because the app's users are technical, the dialog shows:

- a plain-language title (e.g. "Couldn't update bd-1"),
- the exact **`bd` command** that failed, and
- its **output** — both in selectable, monospaced text with a **Copy** button.

Buttons are **Try Again** (re-runs the originating mutation) and **Cancel**. Non-retryable
failures (validation guards, read-only bookmarks) show a single **OK**. Failures are queued
and presented one at a time — never stacked, and exact duplicates are coalesced.

Report failures with `reportMutationFailure(_:title:retry:)`, which extracts the command and
output from `BeadError.commandFailed`. Rollback of the optimistic state happens at failure
time and cannot overwrite a newer user action (the metadata settlement machine guarantees
this). **Try Again** carries the same guarantee a different way: retry closures capture a
`retryBaseline` of the affected issues at failure time and drop the retry silently if any of
them changed since — because writes are serialized, a failure can surface after later edits
already landed, and blindly re-running it would clobber the newer action.

Form-field validation inside a modal config sheet (adding a custom type/status) is a
deliberate exception: it shows the message inline in the sheet's footer, where the user is
typing, and pops the failure from the shared queue so it does not later resurface as a dialog.

### 4. Quiet reconciliation

After a write, the app silently re-exports and reloads the readable snapshot. This expected
self-initiated reconciliation must not flash the "Snapshot may be stale" notice: it reuses the
`LoadedProject.snapshotRefreshWarning == nil` clean-reconcile path. Only a genuinely failed or
externally-stale snapshot surfaces that notice.

## Adding a new mutation surface

1. Apply optimistic state, write through `bd`, reconcile — follow an existing method in
   `BeadStore+Mutations.swift` as the template.
2. In the failure `catch`, call `reportMutationFailure(error, title:, retry:)`. Provide a
   `retry` closure (`[weak self]`, re-invoking the same method with the same arguments) unless
   retrying would be unsafe (e.g. a create that already succeeded but failed to refresh).
3. For a meaningful completion, call `announceCompletion(_:)` on the success path.
4. If the surface has inline controls and its writes can be slow, wrap the write in
   `beginPerceptibleBusy(issueIDs:)` / `endPerceptibleBusy(_:)` and show the indicator locally.
