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

    static func compactTitle(for gate: BeadGate) -> String {
        switch gate.awaitType {
        case .human: "Approval gate"
        case .timer: "Timer gate"
        case .githubRun: "GitHub run gate"
        case .githubPR: "GitHub PR gate"
        case .bead: "Bead gate"
        case let .other(raw): raw.isEmpty ? "Gate" : "\(raw) gate"
        }
    }

    static func timerRemainingText(for gate: BeadGate, now: Date = Date()) -> String? {
        guard gate.awaitType == .timer, let expiresAt = gate.expiresAt else { return nil }
        guard expiresAt > now else { return "elapsed" }
        return "\(durationText(expiresAt.timeIntervalSince(now))) left"
    }

    static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(interval / 60)))
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }

        let totalHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if totalHours < 24 {
            if minutes > 0, totalHours < 10 {
                return "\(totalHours)h \(minutes)m"
            }
            return "\(totalHours)h"
        }

        let days = totalHours / 24
        let hours = totalHours % 24
        if hours > 0, days < 10 {
            return "\(days)d \(hours)h"
        }
        return "\(days)d"
    }

    static func actionTitles(for gate: BeadGate) -> [String] {
        guard gate.isOpen else { return [] }
        switch gate.awaitType {
        case .human:
            return ["Approve...", "Reject..."]
        default:
            return ["Resolve...", "Check"]
        }
    }
}
