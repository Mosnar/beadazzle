import SwiftUI

struct SidebarPreviewIDHeader: View {
    let issueID: String

    var body: some View {
        HStack(spacing: 8) {
            CopyableIssueIDButton(issueID: issueID, width: nil)

            Spacer(minLength: 8)
        }
    }
}
