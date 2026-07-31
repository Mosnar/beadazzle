import SwiftUI

struct IssueBodySections: View {
    let documentIDPrefix: String
    let issue: BeadIssue?
    @Binding var draft: IssueDraft
    let textSectionLayout: IssueTextSectionLayout
    let revealTextSection: (IssueTextSection) -> Void
    let hideTextSection: (IssueTextSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(textSectionLayout.visible) { section in
                EditableTextSection(
                    section: section,
                    text: textBinding(for: section),
                    documentID: documentID(for: section),
                    canHide: IssueTextSectionPresentationPolicy.canHide(section, in: draft),
                    hideAction: { hideTextSection(section) }
                )
            }

            if !textSectionLayout.hidden.isEmpty {
                Menu {
                    ForEach(textSectionLayout.hidden) { section in
                        Button(section.title) {
                            revealTextSection(section)
                        }
                    }

                    if textSectionLayout.hidden.count > 1 {
                        Divider()
                        Button("Show All Sections") {
                            textSectionLayout.hidden.forEach(revealTextSection)
                        }
                    }
                } label: {
                    Label("Add Section", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(AddTextSectionButtonStyle())
                .fixedSize()
                .accessibilityHint("Shows another optional text section in this bead")
            }

            if let issue {
                SubIssuesView(issue: issue)
                ActivityView(issue: issue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func documentID(for section: IssueTextSection) -> String {
        section.documentID(prefix: documentIDPrefix)
    }

    private func textBinding(for section: IssueTextSection) -> Binding<String> {
        Binding {
            section.text(in: draft)
        } set: { updatedText in
            let existingText = section.text(in: draft)
            if IssueTextSectionPresentationPolicy.shouldRevealAfterEditing(
                existingText: existingText,
                updatedText: updatedText
            ) {
                revealTextSection(section)
            }
            setText(updatedText, for: section)
        }
    }

    private func setText(_ text: String, for section: IssueTextSection) {
        switch section {
        case .description:
            draft.description = text
        case .acceptanceCriteria:
            draft.acceptanceCriteria = text
        case .design:
            draft.design = text
        case .notes:
            draft.notes = text
        }
    }
}

private struct AddTextSectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AddTextSectionButtonControl(
            label: configuration.label,
            isPressed: configuration.isPressed
        )
    }
}

private struct AddTextSectionButtonControl<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let isHighlighted = isHovered || isPressed || isFocused

        label
            .font(.callout)
            .foregroundStyle(isHighlighted ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: DetailToolbarActionMetrics.cornerRadius))
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: DetailToolbarActionMetrics.cornerRadius)
                        .fill(Color.primary.opacity(backgroundOpacity))
                }
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: DetailToolbarActionMetrics.cornerRadius)
                        .stroke(.tint.opacity(0.75), lineWidth: 1)
                }
            }
            .onHover { isHovered = $0 }
    }

    private var backgroundOpacity: Double {
        if isPressed {
            0.14
        } else if isFocused {
            0.12
        } else {
            0.08
        }
    }
}
