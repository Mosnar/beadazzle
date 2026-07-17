import AppKit

/// Unified mutation feedback: a single place to report failures (extracting the `bd`
/// command and output when present), drive the standardized error dialog, and post
/// VoiceOver announcements for meaningful failures and completions.
///
/// See `docs/FEEDBACK_POLICY.md` for the disposition model this implements.
extension BeadStore {
    // MARK: Reporting failures

    /// Reports a mutation failure through the single feedback channel. When `error` is a
    /// `BeadError.commandFailed`, the failing command line and its output are surfaced
    /// verbatim in the dialog; otherwise the localized description is shown. Pass `retry`
    /// to offer a "Try Again" button that re-runs the originating mutation.
    func reportMutationFailure(
        _ error: Error,
        title: String,
        retry: (() async -> Void)? = nil
    ) {
        let failure: BeadMutationFailure
        if case let BeadError.commandFailed(command, output) = error {
            failure = BeadMutationFailure(
                title: title,
                message: "The Beads command failed.",
                command: command,
                output: output,
                retry: retry
            )
        } else {
            failure = BeadMutationFailure(
                title: title,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                retry: retry
            )
        }
        enqueueFailure(failure)
    }

    /// Reports bulk failures in one retryable dialog. Counts and retry targets stay
    /// exact; verbose per-command diagnostics are bounded for very large selections.
    func reportBulkMutationFailure(
        _ failures: BulkMutationFailureCollection,
        title: String,
        retry: (() async -> Void)? = nil
    ) {
        guard !failures.isEmpty else { return }
        if failures.commandCount == 1, let failure = failures.details.first {
            enqueueFailure(BeadMutationFailure(
                title: title,
                message: failure.command == nil ? failure.output : "The Beads command failed.",
                command: failure.command,
                output: failure.command == nil ? nil : failure.output,
                retry: retry
            ))
            return
        }

        var sections = failures.details.enumerated().map { offset, failure in
            let displayedIssueIDs = failure.issueIDs.prefix(20)
            let omittedIssueIDCount = failure.issueIDs.count - displayedIssueIDs.count
            var beadSummary = displayedIssueIDs.joined(separator: ", ")
            if omittedIssueIDCount > 0 {
                beadSummary += " … and \(omittedIssueIDCount.formatted()) more"
            }
            var lines = [
                "Failure \(offset + 1)",
                "Beads: \(beadSummary)"
            ]
            if let command = failure.command?.nilIfBlank {
                lines.append("Command: \(command)")
            }
            if !failure.output.isEmpty {
                lines.append("Output:\n\(failure.output)")
            }
            return lines.joined(separator: "\n")
        }
        if failures.omittedDetailCount > 0 {
            sections.append("… \(failures.omittedDetailCount.formatted()) additional failures omitted")
        }
        enqueueFailure(BeadMutationFailure(
            title: title,
            message: "\(failures.commandCount.formatted()) commands failed while processing \(failures.issueIDs.count.formatted()) beads. Successful changes were kept.",
            output: sections.joined(separator: "\n\n"),
            retry: retry
        ))
    }

    /// Enqueues a structured failure, coalescing exact duplicates so a repeated failure
    /// does not stack identical dialogs, and announces it to assistive technology.
    func enqueueFailure(_ failure: BeadMutationFailure) {
        guard !pendingFailures.contains(where: { $0.hasSameContent(as: failure) }) else { return }
        pendingFailures.append(failure)
        announce(failure.accessibilityAnnouncement, priority: .high)
    }

    /// Removes and returns the most recently enqueued failure. Used by surfaces that show
    /// their own inline error (e.g. form-validation sheets) for a failure they just caused,
    /// so it never also appears in the dialog — without disturbing older queued failures.
    @discardableResult
    func consumeMostRecentFailure() -> BeadMutationFailure? {
        pendingFailures.popLast()
    }

    // MARK: Retry validity

    /// Captures the affected issues' state at failure time (after rollback). A queued retry
    /// is only valid while that state is unchanged: writes are serialized, so a failure can
    /// surface after later edits were already made, and blindly re-running the failed write
    /// would overwrite the newer action — the same hazard the metadata settlement machine
    /// guards rollback against.
    func retryBaseline(for issueIDs: [String]) -> [String: BeadIssue] {
        var baseline: [String: BeadIssue] = [:]
        for id in issueIDs {
            if let issue = index.issue(with: id) {
                baseline[id] = issue
            }
        }
        return baseline
    }

    /// Whether every issue captured at failure time is still in exactly that state. When
    /// this fails, the retry is dropped silently — the user's newer action stands.
    func retryBaselineHolds(_ baseline: [String: BeadIssue]) -> Bool {
        baseline.allSatisfy { id, issue in index.issue(with: id) == issue }
    }

    // MARK: Dialog actions

    /// Dismisses the presented failure (Cancel / OK). The optimistic state was already
    /// rolled back at failure time, so dismissing simply accepts the current state.
    func dismissCurrentFailure() {
        guard !pendingFailures.isEmpty else { return }
        pendingFailures.removeFirst()
    }

    /// Re-runs the presented failure's originating mutation (Try Again). The retry re-enters
    /// the same guarded mutation path, so it cannot overwrite a newer user action.
    func retryCurrentFailure() {
        guard let failure = pendingFailures.first else { return }
        pendingFailures.removeFirst()
        guard let retry = failure.retry else { return }
        Task { @MainActor in
            await retry()
        }
    }

    // MARK: Deferred local progress

    /// How long a write may run before it's considered perceptibly slow and earns a local
    /// progress indicator. Fast writes settle first and stay quiet.
    private static let perceptibleLatencyThreshold: Duration = .milliseconds(500)

    /// Begins tracking a write against the given issue anchors. Returns a token to pass to
    /// `endPerceptibleBusy`. The anchors only become "busy" (visible) if the write outlives
    /// `perceptibleLatencyThreshold`; a write that settles first never shows a spinner.
    func beginPerceptibleBusy(issueIDs: Set<String>) -> Int {
        guard !issueIDs.isEmpty else { return -1 }
        perceptibleBusyTokenSeed += 1
        let token = perceptibleBusyTokenSeed
        perceptibleBusyAnchors[token] = issueIDs
        perceptibleBusyTasks[token] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.perceptibleLatencyThreshold)
            guard let self, !Task.isCancelled else { return }
            self.perceptiblyBusyIssueIDs.formUnion(issueIDs)
        }
        return token
    }

    /// Ends tracking for a token: cancels its pending timer and clears its anchors unless
    /// another in-flight write still holds them.
    func endPerceptibleBusy(_ token: Int) {
        guard token >= 0 else { return }
        perceptibleBusyTasks.removeValue(forKey: token)?.cancel()
        guard let anchors = perceptibleBusyAnchors.removeValue(forKey: token) else { return }
        let stillHeld = Set(perceptibleBusyAnchors.values.flatMap { $0 })
        perceptiblyBusyIssueIDs.subtract(anchors.subtracting(stillHeld))
    }

    /// Whether an inline control for this issue should show a local progress indicator.
    func isPerceptiblyBusy(issueID: String) -> Bool {
        perceptiblyBusyIssueIDs.contains(issueID)
    }

    // MARK: Accessibility announcements

    /// Announces a meaningful completion (create/delete/close/relationship change) to
    /// VoiceOver. Successful quick writes are otherwise silent per the feedback policy.
    func announceCompletion(_ text: String) {
        announce(text, priority: .medium)
    }

    /// Posts a VoiceOver announcement anchored to the key window. Failures are announced
    /// at high priority so they interrupt; completions at medium priority.
    private func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // `NSApp` is nil in headless contexts (e.g. unit tests); there's nothing to
        // announce to, so skip rather than crash on the implicitly-unwrapped optional.
        guard let app: NSApplication = NSApp else { return }
        let element: Any = app.keyWindow ?? app.mainWindow ?? app
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: trimmed,
                .priority: priority.rawValue
            ]
        )
    }
}
