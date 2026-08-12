import SwiftUI

struct DisplaySettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                Toggle("Show Back button", isOn: $store.showsBackNavigationButton)
                Toggle("Show Forward button", isOn: $store.showsForwardNavigationButton)
            } header: {
                Text("Navigation")
            }

            Section {
                Picker("Row density", selection: $store.beadListDensity) {
                    ForEach(BeadListDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(
                    "Show all children, even if they don’t match filters",
                    isOn: $store.showsAllChildrenInOutline
                )
                Toggle(
                    "Open split view when clicking a bead",
                    isOn: $store.opensSplitViewOnSingleClick
                )
            } header: {
                Text("Bead List")
            } footer: {
                Text(
                    """
                    Row density keeps the list virtualized at every size. Showing all children only affects expanded beads in Outline mode. \
                    When split view opening is disabled, double-click a bead to open it.
                    """
                )
            }

            Section {
                Toggle("Show bead ID under title", isOn: $store.showsBeadIDUnderTitle)
                Toggle(
                    "Show Copy Bead ID button in breadcrumbs",
                    isOn: $store.showsCopyBeadIDButtonInBreadcrumbs
                )
                Toggle(
                    "Show project name in breadcrumbs",
                    isOn: $store.showsProjectNameInBreadcrumbs
                )
            } header: {
                Text("Bead Detail")
            }

            Section {
                Toggle("Show closed beads", isOn: $store.showsClosedBeadsInSidebar)
                Toggle("Show gates", isOn: $store.showsGatesInSidebar)
                Toggle(
                    "Show sections with zero beads",
                    isOn: $store.showsZeroCountSidebarSections
                )
            } header: {
                Text("Sidebar")
            }
        }
        .settingsGroupedForm()
    }
}
