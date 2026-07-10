import SwiftUI

private enum AppSettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .updates:
            "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .updates:
            "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var updater: UpdaterController
    @SceneStorage("Beadazzle.Settings.SelectedPane") private var selectedPaneRawValue = AppSettingsPane.general.rawValue

    private var selectedPane: Binding<AppSettingsPane> {
        Binding {
            activePane
        } set: { pane in
            selectedPaneRawValue = pane.rawValue
        }
    }

    private var activePane: AppSettingsPane {
        let requestedPane = AppSettingsPane(rawValue: selectedPaneRawValue) ?? .general
        return availablePanes.contains(requestedPane) ? requestedPane : .general
    }

    private var availablePanes: [AppSettingsPane] {
        AppSettingsPane.allCases.filter { pane in
            pane != .updates || updater.isUpdateCheckingAvailable
        }
    }

    var body: some View {
        SettingsPaneContainer(
            panes: availablePanes,
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
        case .updates:
            UpdatesSettingsPane()
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

        }
        .settingsGroupedForm()
    }

    private func chooseBDCLIPath() {
        guard let url = PanelService.chooseExecutable(title: "Choose bd CLI") else { return }
        store.bdCLIPath = url.path
    }
}

private struct UpdatesSettingsPane: View {
    @EnvironmentObject private var updater: UpdaterController

    var body: some View {
        Form {
            Section("Software Update") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Receive beta updates", isOn: $updater.receivesBetaUpdates)
            }

            Section {
                Text("Beta updates deliver pre-release builds as soon as they ship. Turn this off to only receive stable releases once they are available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsGroupedForm()
    }
}
