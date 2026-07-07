import Foundation

enum BeadCompletionAction: Equatable, Sendable {
    case close
    case reopen
}

struct BeadIssueWorkflowActions: Equatable, Sendable {
    var canCreateGate: Bool
    var completionAction: BeadCompletionAction
    var completionTitle: String
    var completionSystemImage: String
}

enum BeadIssueWorkflowPolicy {
    static func actions(for issue: BeadIssue, isDone: Bool) -> BeadIssueWorkflowActions {
        let completionAction: BeadCompletionAction = isDone ? .reopen : .close
        return BeadIssueWorkflowActions(
            canCreateGate: canCreateGate(blocking: issue, isDone: isDone),
            completionAction: completionAction,
            completionTitle: completionTitle(for: completionAction, issueCount: 1, hasMixedCompletionState: false),
            completionSystemImage: completionSystemImage(for: completionAction)
        )
    }

    static func canCreateGate(blocking issue: BeadIssue, isDone: Bool) -> Bool {
        !isDone && !issue.isGate
    }

    static func completionAction(for issues: [BeadIssue], isDone: (BeadIssue) -> Bool) -> BeadCompletionAction {
        guard !issues.isEmpty, issues.allSatisfy(isDone) else {
            return .close
        }
        return .reopen
    }

    static func completionTitle(
        issueCount: Int,
        issues: [BeadIssue],
        isDone: (BeadIssue) -> Bool
    ) -> String {
        let action = completionAction(for: issues, isDone: isDone)
        let hasDoneIssue = issues.contains(where: isDone)
        let hasOpenIssue = issues.contains { !isDone($0) }
        return completionTitle(
            for: action,
            issueCount: issueCount,
            hasMixedCompletionState: hasDoneIssue && hasOpenIssue
        )
    }

    static func completionSystemImage(for action: BeadCompletionAction) -> String {
        switch action {
        case .close:
            "checkmark.circle"
        case .reopen:
            "arrow.uturn.backward.circle"
        }
    }

    private static func completionTitle(
        for action: BeadCompletionAction,
        issueCount: Int,
        hasMixedCompletionState: Bool
    ) -> String {
        switch action {
        case .close:
            if issueCount > 1, hasMixedCompletionState {
                return "Close Open Selected..."
            }
            return issueCount == 1 ? "Close Bead..." : "Close Selected..."
        case .reopen:
            return issueCount == 1 ? "Reopen Bead" : "Reopen Selected"
        }
    }
}
