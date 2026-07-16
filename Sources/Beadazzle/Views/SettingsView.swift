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
    @State private var isShowingResolutionDetails = false
    @State private var versionCheck = BeadsCLIVersionCheck.checking

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                TextField("Path", text: $store.bdCLIPath, prompt: Text("Automatic"))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(store.bdCLIPathValidationMessage, systemImage: validationSystemImage)
                            .font(.callout)
                            .foregroundStyle(validationForegroundStyle)
                            .fixedSize(horizontal: false, vertical: true)

                        versionStatus
                            .font(.callout)
                    }

                    Spacer(minLength: 12)

                    Button("Choose…") {
                        chooseBDCLIPath()
                    }

                    Button("Reset") {
                        store.bdCLIPath = ""
                    }
                    .disabled(store.bdCLIPath.isEmpty)
                }
                .padding(.vertical, 2)

                SettingsDisclosure(
                    title: "Resolution Details",
                    isExpanded: $isShowingResolutionDetails
                ) {
                    SettingsDetailRow("Resolved Path") {
                        Text(store.resolvedBDCLIPathDisplay)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(store.resolvedBDCLIPathDisplay)
                    }
                }
            } header: {
                Text("bd CLI")
            } footer: {
                Text("Leave the path empty to find bd from the environment and standard installation directories.")
            }
        }
        .settingsGroupedForm()
        .task(id: store.bdCLIPath) {
            versionCheck = .checking
            // Debounce keystrokes in the path field so we don't spawn a probe per character.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let result = await BeadsCLIVersionProbe.check()
            guard !Task.isCancelled else { return }
            versionCheck = result
        }
    }

    @ViewBuilder
    private var versionStatus: some View {
        switch versionCheck {
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking bd…")
            }
            .foregroundStyle(.secondary)
        case .valid(let version):
            Label {
                Text("bd \(version)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .help("bd \(version)")
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasInvalidConfiguredPath: Bool {
        let path = store.bdCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && !FileManager.default.isExecutableFile(atPath: path)
    }

    private var validationSystemImage: String {
        if hasInvalidConfiguredPath {
            return "exclamationmark.triangle.fill"
        }
        return store.bdCLIPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "info.circle"
            : "checkmark.circle.fill"
    }

    private var validationForegroundStyle: Color {
        hasInvalidConfiguredPath ? .orange : .secondary
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
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Receive beta updates", isOn: $updater.receivesBetaUpdates)
            } header: {
                Text("Software Update")
            } footer: {
                Text("Beta updates deliver pre-release builds as soon as they ship. Turn this off to receive only stable releases.")
            }
        }
        .settingsGroupedForm()
    }
}
