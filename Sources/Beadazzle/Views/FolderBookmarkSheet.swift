import SwiftUI

struct FolderBookmarkEditorRequest: Identifiable {
    let id = UUID()
    let initialIssueIDs: [String]
}

struct FolderBookmarkSheet: View {
    @Environment(BeadStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let initialIssueIDs: [String]
    @State private var name: String
    @State private var symbolName = "folder"
    @State private var isChoosingIcon = false
    @FocusState private var nameIsFocused: Bool

    init(initialIssueIDs: [String], suggestedName: String) {
        self.initialIssueIDs = initialIssueIDs
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder")
                .font(.title3.weight(.semibold))

            Text("Folders keep a manually ordered set of beads for planning and agent handoff.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                    .onSubmit(create)
            }

            Text(initialIssueIDs.isEmpty
                 ? "The folder will start empty."
                 : "\(initialIssueIDs.count.formatted()) bead\(initialIssueIDs.count == 1 ? "" : "s") will be added in their current list order.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Folder", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            nameIsFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        guard store.createFolder(
            name: trimmedName,
            symbolName: symbolName,
            issueIDs: initialIssueIDs
        ) != nil else { return }
        dismiss()
    }
}
