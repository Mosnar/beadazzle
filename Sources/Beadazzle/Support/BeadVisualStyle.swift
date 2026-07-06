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

enum IssueClipboard {
    static func copyIssueID(_ issueID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issueID, forType: .string)
    }
}
