import SwiftUI

/// Single source of truth for how gates render across the app (list row, detail, breadcrumb,
/// inspector, ribbon chip) so the icon, tint, and one-line condition stay consistent.
enum GatePresentation {
    /// Open gates read as actionable (accent), resolved ones recede.
    static func tint(isOpen: Bool) -> Color {
        isOpen ? .orange : .secondary
    }

    /// A one-line summary of what the gate is waiting on.
    static func conditionHeadline(for gate: BeadGate, now: Date = Date()) -> String {
        switch gate.awaitType {
        case .timer:
            guard let expiresAt = gate.expiresAt else { return "Timer gate" }
            return expiresAt <= now ? "Timer elapsed" : "Expires \(BeadFormatters.relative(expiresAt))"
        case .human:
            return "Awaiting approval"
        case .githubPR:
            return gate.awaitID.map { "Awaiting PR #\($0)" } ?? "Awaiting PR merge"
        case .githubRun:
            return gate.awaitID.map { "Awaiting run #\($0)" } ?? "Awaiting CI run"
        case .bead:
            return gate.awaitID.map { "Awaiting \($0)" } ?? "Awaiting bead"
        case let .other(raw):
            return raw.isEmpty ? "Gate" : raw
        }
    }
}
