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

struct BulkDetailPage: View {
    var body: some View {
        VStack(spacing: 0) {
            BulkSelectionBreadcrumbBar()

            Divider()

            BulkDetailView()
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

struct BulkDetailView: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(store.selectedIDs.count.formatted()) Beads Selected")
                .font(.title2.weight(.semibold))

            Text("Use Bulk Actions in the toolbar to close, delete, re-prioritize, change status, or change type for the selected beads.")
                .foregroundStyle(.secondary)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(groupedByStatus, id: \.0) { status, count in
                    GridRow {
                        Text(status)
                        Text(count.formatted())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var groupedByStatus: [(String, Int)] {
        let selected = store.issues.filter { store.selectedIDs.contains($0.id) }
        return Dictionary(grouping: selected, by: \.status)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
    }
}
