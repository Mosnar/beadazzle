import SwiftUI

struct InspectorAssigneeRow: View {
    @Binding var assignee: String
    let availableAssignees: [String]

    var body: some View {
        IssueMetadataAssigneeControl(
            assignee: $assignee,
            availableAssignees: availableAssignees
        )
    }
}

struct IssueMetadataAssigneeControl: View {
    @Binding var assignee: String
    let availableAssignees: [String]
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var displayValue: String {
        assignee.nilIfBlank ?? "Unassigned"
    }

    private var labelValue: String {
        if presentation == .ribbonChip, assignee.nilIfBlank == nil {
            return "Assignee"
        }
        return displayValue
    }

    var body: some View {
        let isHighlighted = isHovered || isFocused || isPresented

        Button {
            isPresented.toggle()
        } label: {
            IssueMetadataControlLabel(
                title: "Assignee",
                systemImage: "person.crop.circle",
                tint: .secondary,
                value: labelValue,
                presentation: presentation,
                showsChevron: true,
                isHighlighted: isHighlighted
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Edit assignee")
        .accessibilityLabel("Assignee")
        .accessibilityValue(displayValue)
        .accessibilityHint("Opens the assignee editor")
        .popover(isPresented: $isPresented, arrowEdge: presentation.popoverArrowEdge) {
            AssigneeEditorPopover(
                assignee: $assignee,
                availableAssignees: availableAssignees,
                dismiss: { isPresented = false }
            )
        }
        .frame(maxWidth: presentation.maxWidth, alignment: .leading)
    }
}

private struct AssigneeEditorPopover: View {
    @Binding var assignee: String
    let availableAssignees: [String]
    let dismiss: () -> Void
    @State private var pendingAssignee = ""
    @FocusState private var isFieldFocused: Bool

    private var candidates: [String] {
        let query = pendingAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
        return availableAssignees.lazy
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        let candidates = candidates
        return VStack(alignment: .leading, spacing: 12) {
            Text("Assignee")
                .font(.headline)

            TextField("Assignee", text: $pendingAssignee)
                .focused($isFieldFocused)
                .onSubmit(commit)

            if !candidates.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(candidates, id: \.self) { candidate in
                            InspectorOptionItemRow(
                                title: candidate,
                                isSelected: candidate == pendingAssignee
                            ) {
                                pendingAssignee = candidate
                                commit()
                            }
                        }
                    }
                }
                .frame(maxHeight: 188)
            }

            HStack {
                Button("Unassign", action: unassign)
                    .disabled(pendingAssignee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Done", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .onAppear {
            pendingAssignee = assignee
            isFieldFocused = true
        }
    }

    private func unassign() {
        pendingAssignee = ""
        commit()
    }

    private func commit() {
        assignee = pendingAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}
