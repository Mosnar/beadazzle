import SwiftUI

enum IssueMetadataControlPresentation {
    case inspectorRow
    case ribbonChip

    var popoverArrowEdge: Edge {
        switch self {
        case .inspectorRow:
            .trailing
        case .ribbonChip:
            .bottom
        }
    }

    var maxWidth: CGFloat? {
        switch self {
        case .inspectorRow:
            .infinity
        case .ribbonChip:
            nil
        }
    }
}
