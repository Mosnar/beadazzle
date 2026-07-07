import SwiftUI

struct BulkActionsMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var showingDeleteConfirmation: Bool
    let requestCloseSelected: () -> Void

    var body: some View {
        Menu {
            Button(closeTitle) {
                requestCloseSelected()
            }
            .disabled(store.selectedIDs.isEmpty)

            Menu("Set Status") {
                ForEach(store.availableStatuses, id: \.self) { status in
                    Button(status) {
                        Task {
                            await store.bulkSet(status: status)
                        }
                    }
                }
            }
            .disabled(store.selectedIDs.isEmpty)

            Menu("Set Type") {
                ForEach(store.availableTypes, id: \.self) { type in
                    Button(type) {
                        Task {
                            await store.bulkSet(type: type)
                        }
                    }
                }
            }
            .disabled(store.selectedIDs.isEmpty)

            Menu("Set Priority") {
                ForEach(0...4, id: \.self) { priority in
                    Button("P\(priority)") {
                        Task {
                            await store.bulkSet(priority: priority)
                        }
                    }
                }
            }
            .disabled(store.selectedIDs.isEmpty)

            Divider()

            Button("Delete Selected", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(store.selectedIDs.isEmpty)
        } label: {
            Label("Bulk Actions", systemImage: "checklist")
        }
    }

    private var closeTitle: String {
        store.selectedIDs.count == 1 ? "Close Bead..." : "Close Selected..."
    }
}
