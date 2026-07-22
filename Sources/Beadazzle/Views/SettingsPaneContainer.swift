import SwiftUI

struct SettingsPaneGroup<Pane>: Identifiable where Pane: Identifiable & Hashable {
    let id: String
    let title: String?
    let panes: [Pane]

    init(id: String, title: String? = nil, panes: [Pane]) {
        self.id = id
        self.title = title
        self.panes = panes
    }
}

struct SettingsPaneContainer<Pane, SidebarLabel, Detail>: View
where Pane: Identifiable & Hashable, SidebarLabel: View, Detail: View {
    let groups: [SettingsPaneGroup<Pane>]
    @Binding var selection: Pane
    let title: (Pane) -> String
    let minDetailWidth: CGFloat
    let minHeight: CGFloat
    @ViewBuilder let sidebarLabel: (Pane) -> SidebarLabel
    @ViewBuilder let detail: (Pane) -> Detail

    init(
        panes: [Pane],
        selection: Binding<Pane>,
        title: @escaping (Pane) -> String,
        minDetailWidth: CGFloat = 540,
        minHeight: CGFloat = 460,
        @ViewBuilder sidebarLabel: @escaping (Pane) -> SidebarLabel,
        @ViewBuilder detail: @escaping (Pane) -> Detail
    ) {
        self.groups = [SettingsPaneGroup(id: "settings", panes: panes)]
        self._selection = selection
        self.title = title
        self.minDetailWidth = minDetailWidth
        self.minHeight = minHeight
        self.sidebarLabel = sidebarLabel
        self.detail = detail
    }

    init(
        groups: [SettingsPaneGroup<Pane>],
        selection: Binding<Pane>,
        title: @escaping (Pane) -> String,
        minDetailWidth: CGFloat = 540,
        minHeight: CGFloat = 460,
        @ViewBuilder sidebarLabel: @escaping (Pane) -> SidebarLabel,
        @ViewBuilder detail: @escaping (Pane) -> Detail
    ) {
        self.groups = groups
        self._selection = selection
        self.title = title
        self.minDetailWidth = minDetailWidth
        self.minHeight = minHeight
        self.sidebarLabel = sidebarLabel
        self.detail = detail
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groups) { group in
                    if let title = group.title {
                        Section(title) {
                            sidebarRows(group.panes)
                        }
                    } else {
                        sidebarRows(group.panes)
                    }
                }
            }
            .listStyle(.sidebar)
            .padding(.top, SettingsWindowLayout.sidebarTopPadding)
            .navigationSplitViewColumnWidth(
                min: SettingsWindowLayout.sidebarMinWidth,
                ideal: SettingsWindowLayout.sidebarIdealWidth,
                max: SettingsWindowLayout.sidebarMaxWidth
            )
            .accessibilityLabel("Settings Panes")
        } detail: {
            detail(selection)
                .navigationTitle(title(selection))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(SettingsWindowToolbarAppearance())
        .frame(
            minWidth: SettingsWindowLayout.minimumWidth(minDetailWidth: minDetailWidth),
            minHeight: minHeight
        )
    }

    @ViewBuilder
    private func sidebarRows(_ panes: [Pane]) -> some View {
        ForEach(panes) { pane in
            sidebarLabel(pane)
                .tag(pane)
        }
    }
}

enum SettingsWindowLayout {
    static let sidebarMinWidth: CGFloat = 190
    static let sidebarIdealWidth: CGFloat = 220
    static let sidebarMaxWidth: CGFloat = 280
    static let sidebarTopPadding: CGFloat = 8
    static let formMaxWidth: CGFloat = 760
    static let contentMargin: CGFloat = 24

    static let appDefaultWidth: CGFloat = 820
    static let appDefaultHeight: CGFloat = 520
    static let projectDefaultWidth: CGFloat = 880
    static let projectDefaultHeight: CGFloat = 560

    static func minimumWidth(minDetailWidth: CGFloat) -> CGFloat {
        max(756, sidebarMinWidth + minDetailWidth)
    }
}

private struct SettingsWindowToolbarAppearance: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

private struct SettingsGroupedForm: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .contentMargins(.top, 16, for: .scrollContent)
            .contentMargins(.horizontal, SettingsWindowLayout.contentMargin, for: .scrollContent)
            .contentMargins(.bottom, SettingsWindowLayout.contentMargin, for: .scrollContent)
            .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension View {
    func settingsGroupedForm(maxWidth: CGFloat = SettingsWindowLayout.formMaxWidth) -> some View {
        modifier(SettingsGroupedForm(maxWidth: maxWidth))
    }
}
