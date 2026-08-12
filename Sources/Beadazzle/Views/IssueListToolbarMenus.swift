import SwiftUI

struct IssueListSortMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        Menu {
            Section("Sort By") {
                if store.isShowingFolderInIssueList {
                    Button {
                        store.selectManualFolderOrdering()
                    } label: {
                        if store.listOrdering.isManual {
                            Label("Manual", systemImage: "checkmark")
                        } else {
                            Text("Manual")
                        }
                    }
                    Divider()
                }

                ForEach(IssueSort.allCases) { sort in
                    Button {
                        store.selectListSort(sort)
                    } label: {
                        if !store.isShowingFolderInIssueList || !store.listOrdering.isManual,
                           store.sort == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            }

            Divider()

            Button {
                store.selectListSortDirection(.ascending)
            } label: {
                if store.sortDirection == .ascending {
                    Label("Ascending", systemImage: "checkmark")
                } else {
                    Text("Ascending")
                }
            }
            .disabled(store.isShowingFolderInIssueList && store.listOrdering.isManual)

            Button {
                store.selectListSortDirection(.descending)
            } label: {
                if store.sortDirection == .descending {
                    Label("Descending", systemImage: "checkmark")
                } else {
                    Text("Descending")
                }
            }
            .disabled(store.isShowingFolderInIssueList && store.listOrdering.isManual)
        } label: {
            Label(
                store.isShowingFolderInIssueList && store.listOrdering.isManual
                    ? "Manual"
                    : store.sort.rawValue,
                systemImage: "arrow.up.arrow.down"
            )
            .labelStyle(.iconOnly)
            .lineLimit(1)
        }
        .menuIndicator(.hidden)
        .help(
            store.isShowingFolderInIssueList && store.listOrdering.isManual
                ? "Sort: Manual"
                : "Sort: \(store.sort.rawValue)"
        )
        .accessibilityLabel(
            store.isShowingFolderInIssueList && store.listOrdering.isManual
                ? "Sort: Manual"
                : "Sort: \(store.sort.rawValue)"
        )
    }
}

struct IssueListViewOptionsMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        @Bindable var store = store

        Menu {
            Section("Bead Rows") {
                Toggle("Show owner", isOn: $store.showsOwnerInBeadList)
                Toggle("Show assignee", isOn: $store.showsAssigneeInBeadList)
                Toggle("Show due date", isOn: $store.showsDueDateInBeadList)
                Toggle("Show comments", isOn: $store.showsCommentsInBeadList)
            }
        } label: {
            Label("View", systemImage: "eye")
                .labelStyle(.iconOnly)
                .lineLimit(1)
        }
        .menuIndicator(.hidden)
        .disabled(project.projectURL == nil)
        .help(project.projectURL == nil ? "Open a project to change view options" : "View Options")
        .accessibilityLabel("View Options")
    }
}
