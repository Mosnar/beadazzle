import Foundation

struct BlockedReasonPresentation: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case issue
        case gate
        case multiple
        case external
        case resolvedGate
        case unexplained
    }

    enum Tint: Hashable, Sendable {
        case secondary
        case action
        case warning
        case resolved
        case unexplained
    }

    struct Blocker: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case issue
            case gate
            case external
        }

        var kind: Kind
        var inlineTitle: String
        var listTitle: String
        var help: String
        var systemImage: String
        var tint: Tint

        static func issue(_ issue: BeadIssue) -> Blocker {
            let title = "\(issue.id): \(issue.title)"
            return Blocker(
                kind: .issue,
                inlineTitle: title,
                listTitle: title,
                help: title,
                systemImage: "arrow.down.right.and.arrow.up.left",
                tint: .secondary
            )
        }

        static func gate(_ gate: BeadGate, now: Date) -> Blocker {
            let headline = GatePresentation.conditionHeadline(for: gate, now: now)
            let help = [gateHelpTitle(for: gate, headline: headline), gate.reason?.nilIfBlank.map { "Reason: \($0)" }]
                .compactMap(\.self)
                .joined(separator: "\n")
            return Blocker(
                kind: .gate,
                inlineTitle: headline,
                listTitle: "\(gate.id): \(headline)",
                help: help,
                systemImage: gate.awaitType.systemImage,
                tint: gate.actionState(now: now).isReady ? .action : .secondary
            )
        }

        static func external(reference: String) -> Blocker {
            let help = "Blocked by external reference \(reference). The blocker is not present in this project snapshot."
            return Blocker(
                kind: .external,
                inlineTitle: reference,
                listTitle: reference,
                help: help,
                systemImage: "link",
                tint: .warning
            )
        }

        private static func gateHelpTitle(for gate: BeadGate, headline: String) -> String {
            "Gate \(gate.id): \(headline)"
        }
    }

    var kind: Kind
    var title: String
    var help: String
    var systemImage: String
    var tint: Tint

    var accessibilityValue: String {
        help
    }

    static func active(blockers: [Blocker]) -> BlockedReasonPresentation? {
        guard let first = blockers.first else { return nil }
        guard blockers.count == 1 else {
            return multiple(blockers: blockers)
        }

        switch first.kind {
        case .issue:
            return BlockedReasonPresentation(
                kind: .issue,
                title: "Blocked by \(first.inlineTitle)",
                help: first.help,
                systemImage: first.systemImage,
                tint: first.tint
            )
        case .gate:
            return BlockedReasonPresentation(
                kind: .gate,
                title: "Waiting on \(first.inlineTitle)",
                help: first.help,
                systemImage: first.systemImage,
                tint: first.tint
            )
        case .external:
            return BlockedReasonPresentation(
                kind: .external,
                title: "Blocked by external reference",
                help: first.help,
                systemImage: first.systemImage,
                tint: first.tint
            )
        }
    }

    static func resolvedGate(gates: [BeadGate], now: Date) -> BlockedReasonPresentation? {
        guard !gates.isEmpty else { return nil }
        let title = gates.count == 1
            ? "Resolved gate; status still blocked"
            : "Resolved gates; status still blocked"
        let gateLines = gates.map { gate in
            let headline = GatePresentation.conditionHeadline(for: gate, now: now)
            let reason = gate.reason?.nilIfBlank.map { " - Reason: \($0)" } ?? ""
            return "Gate \(gate.id): \(headline)\(reason)"
        }
        return BlockedReasonPresentation(
            kind: .resolvedGate,
            title: title,
            help: "All known gate blockers are resolved, but this bead is still marked blocked.\n"
                + gateLines.map { "- \($0)" }.joined(separator: "\n"),
            systemImage: "checkmark.seal",
            tint: .resolved
        )
    }

    static var unexplained: BlockedReasonPresentation {
        BlockedReasonPresentation(
            kind: .unexplained,
            title: "Marked blocked; no active blocker found",
            help: "This bead is marked blocked, but no active blocks dependency was found.",
            systemImage: "questionmark.circle",
            tint: .unexplained
        )
    }

    private static func multiple(blockers: [Blocker]) -> BlockedReasonPresentation {
        let hasExternalBlocker = blockers.contains { $0.kind == .external }
        return BlockedReasonPresentation(
            kind: .multiple,
            title: "Blocked by \(blockers.count.formatted()) blockers: \(blockers[0].listTitle)",
            help: "Blocked by \(blockers.count.formatted()) blockers:\n"
                + blockers.map { "- \($0.help)" }.joined(separator: "\n"),
            systemImage: "arrow.down.right.and.arrow.up.left",
            tint: hasExternalBlocker ? .warning : .secondary
        )
    }
}
