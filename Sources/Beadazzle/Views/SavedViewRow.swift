import SwiftUI

struct SavedViewRow: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let view: BeadSavedView
    let count: Int?
    let countIsLoading: Bool
    let onEdit: () -> Void

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var canceledRename = false
    @State private var isChoosingIcon = false
    @State private var isConfirmingDelete = false
    @State private var isConfirmingFilterReplacement = false
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: view.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            Group {
                if isRenaming {
                    TextField("Bookmark Name", text: $draftName)
                        .focused($nameIsFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: nameIsFocused) { oldValue, newValue in
                            if oldValue, !newValue, isRenaming {
                                canceledRename ? finishRename() : commitRename()
                            }
                        }
                } else {
                    Text(view.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .layoutPriority(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if let count {
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("\(count.formatted()) beads")
            } else if countIsLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Updating bookmark count")
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit Bookmark...", action: onEdit)
            Button("Update from Current View") {
                if store.updateWouldReplaceAdvancedRules(id: view.id) {
                    isConfirmingFilterReplacement = true
                } else {
                    store.updateSavedViewFilterFromCurrentState(id: view.id)
                }
            }
            Button("Rename", action: beginRename)
            Button("Change Icon...") { isChoosingIcon = true }
            Button("Duplicate") { store.duplicateSavedView(id: view.id) }
            Divider()
            Button("Move Up") { store.moveSavedViewUp(id: view.id) }
                .disabled(!store.canMoveSavedViewUp(id: view.id))
            Button("Move Down") { store.moveSavedViewDown(id: view.id) }
                .disabled(!store.canMoveSavedViewDown(id: view.id))
            Divider()
            Button("Delete...", role: .destructive) { isConfirmingDelete = true }
        }
        .popover(isPresented: $isChoosingIcon) {
            SavedViewIconPicker(selection: Binding(
                get: { view.symbolName },
                set: {
                    store.setSavedViewSymbol(id: view.id, symbolName: $0)
                    isChoosingIcon = false
                }
            ))
            .padding()
        }
        .alert("Delete “\(view.name)” Bookmark?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { store.deleteSavedView(id: view.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local bookmark. It does not change any beads.")
        }
        .alert("Replace Advanced Rules?", isPresented: $isConfirmingFilterReplacement) {
            Button("Replace", role: .destructive) {
                store.updateSavedViewFilterFromCurrentState(id: view.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current view uses different advanced rules. Updating this bookmark will replace its saved rules.")
        }
    }

    private func beginRename() {
        draftName = view.name
        canceledRename = false
        isRenaming = true
        Task { @MainActor in
            await Task.yield()
            nameIsFocused = true
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        store.renameSavedView(id: view.id, to: draftName)
        finishRename()
    }

    private func cancelRename() {
        guard isRenaming else { return }
        canceledRename = true
        draftName = view.name
        nameIsFocused = false
    }

    private func finishRename() {
        isRenaming = false
        canceledRename = false
        nameIsFocused = false
    }
}
