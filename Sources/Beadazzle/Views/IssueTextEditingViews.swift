import SwiftUI

struct IssueTitleBlock: View {
    @Binding var draft: IssueDraft
    let focusesTitle: Bool
    @FocusState private var isTitleFocused: Bool

    init(draft: Binding<IssueDraft>, focusesTitle: Bool = false) {
        self._draft = draft
        self.focusesTitle = focusesTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Untitled bead", text: $draft.title, axis: .vertical)
                .focused($isTitleFocused)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .lineLimit(1...4)
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: focusesTitle) {
            guard focusesTitle else { return }
            isTitleFocused = true
        }
    }
}

enum IssueTextSection: Hashable {
    case description
    case acceptanceCriteria
    case design
    case notes

    var title: String {
        switch self {
        case .description:
            return "Description"
        case .acceptanceCriteria:
            return "Acceptance Criteria"
        case .design:
            return "Design"
        case .notes:
            return "Notes"
        }
    }

    var placeholder: String {
        switch self {
        case .description:
            return "Add description..."
        case .acceptanceCriteria:
            return "Add acceptance criteria..."
        case .design:
            return "Add design notes..."
        case .notes:
            return "Add notes..."
        }
    }

    var storageKey: String {
        switch self {
        case .description:
            return "description"
        case .acceptanceCriteria:
            return "acceptance-criteria"
        case .design:
            return "design"
        case .notes:
            return "notes"
        }
    }

    var minimumLineCount: Int {
        switch self {
        case .description:
            return 3
        case .acceptanceCriteria, .design:
            return 3
        case .notes:
            return 2
        }
    }
}

struct EditableTextSection: View {
    let section: IssueTextSection
    @Binding var text: String
    let documentID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.semibold))

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
