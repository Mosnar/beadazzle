import SwiftUI

struct FolderBookmarkEditorRequest: Identifiable {
    let id = UUID()
    let folderID: UUID?
    let initialIssueIDs: [String]

    init(initialIssueIDs: [String]) {
        folderID = nil
        self.initialIssueIDs = initialIssueIDs
    }

    init(folderID: UUID) {
        self.folderID = folderID
        initialIssueIDs = []
    }
}

struct FolderBookmarkSheet: View {
    @Environment(BeadStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let folderID: UUID?
    let initialIssueIDs: [String]
    @State private var name: String
    @State private var symbolName: String
    @State private var automationDraft: BeadFolderAutomationDraft
    @State private var isChoosingIcon = false
    @FocusState private var nameIsFocused: Bool

    init(
        initialIssueIDs: [String],
        suggestedName: String,
        existing: BeadSavedView? = nil
    ) {
        folderID = existing?.id
        self.initialIssueIDs = initialIssueIDs
        let automation = existing?.folder?.automation ?? BeadFolderAutomation()
        _name = State(initialValue: existing?.name ?? suggestedName)
        _symbolName = State(initialValue: existing?.symbolName ?? "folder")
        _automationDraft = State(initialValue: BeadFolderAutomationDraft(
            automation: automation
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(folderID == nil ? "New Folder" : "Edit Folder")
                .font(.title3.weight(.semibold))

            Text("Folders keep a manually ordered set of beads. Optional actions run whenever beads are added; they do not filter folder contents.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            folderIdentity

            if folderID == nil {
                Text(initialIssueIDs.isEmpty
                     ? "The folder will start empty."
                     : "\(initialIssueIDs.count.formatted()) bead\(initialIssueIDs.count == 1 ? "" : "s") will be added in their current list order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            FolderAutomationEditor(
                folderName: trimmedName,
                validationMessage: automationValidationMessage,
                draft: $automationDraft
            )

            footer
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if folderID == nil {
                nameIsFocused = true
            }
        }
    }

    private var folderIdentity: some View {
        HStack(spacing: 10) {
            Button {
                isChoosingIcon = true
            } label: {
                Image(systemName: symbolName)
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Choose folder icon")
            .accessibilityLabel("Choose folder icon")
            .popover(isPresented: $isChoosingIcon) {
                SavedViewIconPicker(selection: Binding(
                    get: { symbolName },
                    set: {
                        symbolName = $0
                        isChoosingIcon = false
                    }
                ))
                .padding()
            }

            TextField("Folder Name", text: $name)
                .focused($nameIsFocused)
                .onSubmit(save)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if folderID != nil, automationDraft.hasConfiguredAction {
                Button("Apply Now") {
                    guard saveChanges(), let folderID else { return }
                    store.applyFolderAutomationNow(folderID: folderID)
                    dismiss()
                }
                .disabled(!canSave)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(folderID == nil ? "Create Folder" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
    }

    private var automation: BeadFolderAutomation {
        automationValidation.automation
    }

    private var automationValidation: BeadFolderAutomationValidation {
        store.folderAutomationValidation(automationDraft.automation)
    }

    private var automationValidationMessage: String? {
        automationDraft.incompleteActionMessage ?? automationValidation.message
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && automationValidationMessage == nil
    }

    private func save() {
        guard saveChanges() else { return }
        dismiss()
    }

    private func saveChanges() -> Bool {
        guard canSave else { return false }
        if let folderID {
            return store.updateFolder(
                id: folderID,
                name: trimmedName,
                symbolName: symbolName,
                automation: automation
            )
        }
        return store.createFolder(
            name: trimmedName,
            symbolName: symbolName,
            issueIDs: initialIssueIDs,
            automation: automation
        ) != nil
    }
}
