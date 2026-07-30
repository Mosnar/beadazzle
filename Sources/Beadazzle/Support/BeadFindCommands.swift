import SwiftUI

/// Find-in-bead target the detail pane publishes for the Edit ▸ Find menu.
///
/// Holds the session reference and plain availability flags rather than closures:
/// closures aren't comparable, so a value carrying them looks different on every
/// evaluation and forces the focused-value environment and the commands that read
/// it to invalidate each time results arrive.
///
/// Published with `.focusedSceneValue`, not `.focusedValue`. `.focusedValue` only
/// propagates while something *inside* the detail pane holds focus, which left
/// Edit ▸ Find disabled whenever focus sat in the sidebar, the issue list, or the
/// search field — and made ⌘F escalation impossible, since escalating requires
/// the search field to have focus, which is exactly when the detail pane is out
/// of the focus chain. Scene scope is safe because `ContentView` instantiates one
/// `DetailView` per scene.
struct BeadFindActions: Equatable {
    /// Stable for the lifetime of the window, so identity comparison suffices.
    let session: BeadFindSession
    /// What find would search if invoked now; `nil` when nothing is searchable.
    let scope: BeadFindScope?
    /// Whether stepping between matches is possible right now. Computed where
    /// the session's observable state is actually tracked.
    let canStepBetweenMatches: Bool

    var canFindInCurrent: Bool {
        scope != nil
    }

    static func == (lhs: BeadFindActions, rhs: BeadFindActions) -> Bool {
        lhs.session === rhs.session
            && lhs.scope == rhs.scope
            && lhs.canStepBetweenMatches == rhs.canStepBetweenMatches
    }

    @MainActor
    func findInCurrent() {
        guard let scope else { return }
        session.open(scope: scope)
    }

    @MainActor
    func findNext() {
        guard canStepBetweenMatches else { return }
        session.moveToNextMatch()
    }

    @MainActor
    func findPrevious() {
        guard canStepBetweenMatches else { return }
        session.moveToPreviousMatch()
    }
}

extension FocusedValues {
    @Entry var beadFindActions: BeadFindActions?
}
