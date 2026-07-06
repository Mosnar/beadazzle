import SwiftUI

private enum AppSettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case ui

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .ui:
            "UI"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .ui:
            "sidebar.leading"
        }
    }
}

struct SettingsView: View {
    @SceneStorage("Beadazzle.Settings.SelectedPane") private var selectedPaneRawValue = AppSettingsPane.general.rawValue

    private var selectedPane: Binding<AppSettingsPane> {
        Binding {
            activePane
        } set: { pane in
            selectedPaneRawValue = pane.rawValue
        }
    }

    private var activePane: AppSettingsPane {
        AppSettingsPane(rawValue: selectedPaneRawValue) ?? .general
    }

    var body: some View {
        SettingsPaneContainer(
            panes: Array(AppSettingsPane.allCases),
            selection: selectedPane,
            title: \.title,
            minDetailWidth: 560,
            minHeight: 460
        ) { pane in
            Label(pane.title, systemImage: pane.systemImage)
        } detail: { pane in
            AppSettingsDetail(pane: pane)
        }
    }
}

private struct AppSettingsDetail: View {
    let pane: AppSettingsPane

    var body: some View {
        switch pane {
        case .general:
            GeneralSettingsPane()
        case .ui:
            UISettingsPane()
        }
    }
}

private struct GeneralSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Form {
            Section("bd CLI") {
                LabeledContent("Path") {
                    HStack(spacing: 8) {
                        TextField("Automatic", text: $store.bdCLIPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280)

                        Button("Choose...") {
                            chooseBDCLIPath()
                        }

                        Button("Reset") {
                            store.bdCLIPath = ""
                        }
                        .disabled(store.bdCLIPath.isEmpty)
                    }
                }

                LabeledContent("Status") {
                    Text(store.bdCLIPathValidationMessage)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Resolved") {
                    Text(store.resolvedBDCLIPathDisplay)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Staleness") {
                LabeledContent("Cut-off") {
                    Stepper(value: $store.staleCutoffDays, in: 1...365) {
                        Text("\(store.staleCutoffDays.formatted()) days")
                            .monospacedDigit()
                    }
                }
            }
        }
        .settingsGroupedForm()
    }

    private func chooseBDCLIPath() {
        guard let url = PanelService.chooseExecutable(title: "Choose bd CLI") else { return }
        store.bdCLIPath = url.path
    }
}

private struct UISettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Beads") {
                Toggle("Show owner", isOn: $store.showsOwnerInBeadList)
                Toggle("Show assignee", isOn: $store.showsAssigneeInBeadList)
                Toggle("Show due date", isOn: $store.showsDueDateInBeadList)
                Toggle("Show comments", isOn: $store.showsCommentsInBeadList)
            }
        }
        .settingsGroupedForm()
    }
}
