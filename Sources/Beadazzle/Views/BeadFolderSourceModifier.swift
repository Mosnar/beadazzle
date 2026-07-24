import SwiftUI

private struct BeadFolderSourceModifier: ViewModifier {
    @Environment(BeadStore.self) private var store
    let issueID: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let payload = store.beadDragPayload(issueID: issueID) {
            content
                .draggable(payload)
                .contextMenu {
                    AddToFolderMenu(issueIDs: [issueID])
                }
        } else {
            content
        }
    }
}

extension View {
    func beadFolderSource(issueID: String) -> some View {
        modifier(BeadFolderSourceModifier(issueID: issueID))
    }
}
