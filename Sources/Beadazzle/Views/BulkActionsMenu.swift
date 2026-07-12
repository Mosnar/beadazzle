import SwiftUI

struct BulkActionsMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var workspace: BeadWorkspaceStore { store.workspace }
    let requestDeleteSelected: () -> Void
    let requestCloseSelected: () -> Void
    let requestSetStatus: (String) -> Void

    var body: some View {
        let statusOptions = store.statusChangeOptions(forIssueIDs: workspace.selectedIDs)

        Menu {
            Button(closeTitle) {
                requestCloseSelected()
            }
            .disabled(workspace.selectedIDs.isEmpty)

            if !statusOptions.isEmpty {
                Menu("Set Status") {
                    ForEach(statusOptions, id: \.self) { status in
                        Button(status) {
                            requestSetStatus(status)
                        }
                    }
                }
            }

            Menu("Set Type") {
                ForEach(store.availableMutableTypes, id: \.self) { type in
                    Button(type) {
                        Task {
                            await store.bulkSet(type: type)
                        }
                    }
                }
            }
            .disabled(!store.canSetTypeForSelection)

            Menu("Set Priority") {
                ForEach(0...4, id: \.self) { priority in
                    Button("P\(priority)") {
                        Task {
                            await store.bulkSet(priority: priority)
                        }
                    }
                }
            }
            .disabled(workspace.selectedIDs.isEmpty)

            Divider()

            Button("Delete Selected", role: .destructive) {
                requestDeleteSelected()
            }
            .disabled(workspace.selectedIDs.isEmpty)
        } label: {
            Label("Bulk Actions", systemImage: "checklist")
        }
    }

    private var closeTitle: String {
        store.completionActionTitle(for: workspace.selectedIDs.sorted())
    }
}
