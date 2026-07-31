import SwiftUI

struct IssueTitleBlock: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft
    let issueID: String?
    let focusesTitle: Bool
    @FocusState private var isTitleFocused: Bool

    init(
        draft: Binding<IssueDraft>,
        issueID: String? = nil,
        focusesTitle: Bool = false
    ) {
        self._draft = draft
        self.issueID = issueID
        self.focusesTitle = focusesTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled bead", text: $draft.title, axis: .vertical)
                .focused($isTitleFocused)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .lineLimit(1...4)
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let issueID, store.showsBeadIDUnderTitle {
                CopyableIssueIDButton(issueID: issueID, width: nil)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: focusesTitle) {
            guard focusesTitle else { return }
            isTitleFocused = true
        }
    }
}

struct EditableTextSection: View {
    let section: IssueTextSection
    @Binding var text: String
    let documentID: String
    let canHide: Bool
    let hideAction: () -> Void
    @State private var isHeaderHovered = false
    @FocusState private var isHideButtonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.title)
                    .font(.title3.weight(.semibold))

                Spacer()

                if canHide {
                    Button(action: hideAction) {
                        DetailToolbarActionLabel()
                    }
                    .buttonStyle(
                        DetailToolbarButtonStyle(
                            systemImage: "eye.slash",
                            isFocused: isHideButtonFocused
                        )
                    )
                    .focused($isHideButtonFocused)
                    .opacity(isHeaderHovered || isHideButtonFocused ? 1 : 0)
                    .allowsHitTesting(isHeaderHovered || isHideButtonFocused)
                    .help("Hide empty \(section.title) section")
                    .accessibilityLabel("Hide \(section.title) section")
                    .accessibilityHint("Keeps this empty section hidden until it is added again")
                }
            }
            .contentShape(.rect)
            .onHover { isHeaderHovered = $0 }

            MarkdownFieldEditor(
                text: $text,
                placeholder: section.placeholder,
                documentID: documentID,
                minimumLineCount: section.minimumLineCount
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
