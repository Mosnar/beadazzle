import SwiftUI

enum BeadNavigationDirection {
    case back
    case forward

    var title: String {
        switch self {
        case .back:
            return "Back"
        case .forward:
            return "Forward"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .back:
            return KeyboardShortcut("[", modifiers: [.command])
        case .forward:
            return KeyboardShortcut("]", modifiers: [.command])
        }
    }
}

