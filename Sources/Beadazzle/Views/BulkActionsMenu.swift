import SwiftUI

struct BulkActionsMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var workspace: BeadWorkspaceStore { store.workspace }
    let requestDeleteSelected: () -> Void
    let requestCloseSelected: () -> Void
    let requestSetStatus: (String) -> Void
    let requestBulkEdit: (BulkEditTarget) -> Void

    var body: some View {
        Menu {
            if !workspace.selectedIDs.isEmpty {
                BulkActionsMenuContent(
                    requestDeleteSelected: requestDeleteSelected,
                    requestCloseSelected: requestCloseSelected,
                    requestSetStatus: requestSetStatus,
                    requestBulkEdit: requestBulkEdit
                )
            }
        } label: {
            Label("Bulk Actions", systemImage: "checklist")
        }
        .disabled(workspace.selectedIDs.isEmpty)
    }
}

private struct BulkActionsMenuContent: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var workspace: BeadWorkspaceStore { store.workspace }
    let requestDeleteSelected: () -> Void
    let requestCloseSelected: () -> Void
    let requestSetStatus: (String) -> Void
    let requestBulkEdit: (BulkEditTarget) -> Void

    var body: some View {
        let statusOptions = store.statusChangeOptions(forIssueIDs: workspace.selectedIDs)
        let propertySections = BulkEditPropertySections(store: store)
        let orderedSelectedIDs = store.orderedIssueIDsForCurrentRows(workspace.selectedIDs)

        if store.canCreateSavedView {
            FolderActionsMenu(issueIDs: orderedSelectedIDs)
            Divider()
        }

        Button("Add Labels…") {
            requestBulkEdit(.addLabels)
        }

        if !propertySections.isEmpty {
            Menu("Set Property") {
                propertyButtons(propertySections.pinned)
                if !propertySections.pinned.isEmpty, !propertySections.other.isEmpty {
                    Divider()
                }
                if !propertySections.other.isEmpty {
                    Menu("Other") {
                        propertyButtons(propertySections.other)
                    }
                }
            }
        }

        Divider()

        Button(closeTitle) {
            requestCloseSelected()
        }

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

        Divider()

        Button("Delete Selected", role: .destructive) {
            requestDeleteSelected()
        }
    }

    private var closeTitle: String {
        store.completionActionTitle(for: workspace.selectedIDs.sorted())
    }

    @ViewBuilder
    private func propertyButtons(_ dimensions: [String]) -> some View {
        ForEach(dimensions, id: \.self) { dimension in
            Button(store.stateDimensionDisplayName(for: dimension)) {
                requestBulkEdit(.setProperty(dimension: dimension))
            }
        }
    }
}
