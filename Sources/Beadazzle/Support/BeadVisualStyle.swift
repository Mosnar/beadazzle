import AppKit
import SwiftUI

enum BeadVisualStyle {
    static func color(forCategory category: BeadStatusCategory) -> Color {
        switch category {
        case .wip:
            Color(nsColor: .systemBlue)
        case .frozen:
            Color(nsColor: .systemOrange)
        case .done:
            Color(nsColor: .systemGreen)
        case .active, .uncategorized:
            Color(nsColor: .secondaryLabelColor)
        }
    }

    static func symbol(forCategory category: BeadStatusCategory) -> String {
        switch category {
        case .active:
            "circle"
        case .wip:
            "play.circle.fill"
        case .frozen:
            "pause.circle.fill"
        case .done:
            "checkmark.circle.fill"
        case .uncategorized:
            "questionmark.circle"
        }
    }

    static func priorityColor(for priority: Int) -> Color {
        switch priority {
        case ...0:
            Color(nsColor: .systemRed)
        case 1:
            Color(nsColor: .systemOrange)
        case 2:
            Color(nsColor: .secondaryLabelColor)
        default:
            Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// Single source of truth for the relationship, hierarchy, and gate SF Symbols that
/// are shared across surfaces. Symbols with a single consumer stay inline at their
/// point of use (e.g. `GateAwaitType.systemImage`).
enum BeadIconography {
    static let blockedBy = "nosign"
    static let blocking = "hand.raised"
    static let children = "list.bullet.indent"
    static let genericGate = "flag.checkered"
    static let externalReference = "link"

    static let humanGate = "person.badge.clock"
    /// Neutral timer glyph: the pre-15.4 fallback and the closed-gate presentation.
    static let plainTimerGate = "timer"
    /// Requires macOS 15.4 (SF Symbols 6.4); the deployment target is macOS 14, so
    /// earlier systems must fall back to `plainTimerGate` at runtime.
    static let preferredTimerGate = "nosign.badge.clock"
    static let timerGate = resolvedSystemName(
        preferred: preferredTimerGate,
        fallback: plainTimerGate
    )

    static func resolvedSystemName(
        preferred: String,
        fallback: String,
        isAvailable: (String) -> Bool = { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        }
    ) -> String {
        isAvailable(preferred) ? preferred : fallback
    }
}

enum IssueClipboard {
    static func copyIssueID(_ issueID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issueID, forType: .string)
    }
}
