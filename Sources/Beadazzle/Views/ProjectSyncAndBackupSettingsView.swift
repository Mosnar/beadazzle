import SwiftUI

struct ProjectSyncAndBackupSettingsPane: View {
    var body: some View {
        Form {
            ProjectSyncStatusSection()
            ProjectExternalRefreshSection()
            ProjectSnapshotSyncSection()
            ProjectDoltSyncSection()
            ProjectBackupSyncSection()
            ProjectGitIntegrationSyncSection()
        }
        .settingsGroupedForm()
        .loadsProjectHealthStatusIfNeeded()
    }
}

private struct ProjectSyncStatusSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section("Status") {
            ProjectHealthStatusSummary(
                action: project.projectHealthAction,
                isLoading: project.isLoadingProjectHealth,
                loadedAt: project.projectHealthSnapshot?.loadedAt
            )

            if let actionError = project.projectHealthActionError {
                ProjectHealthMessageRow(
                    title: actionError.title,
                    message: actionError.message,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }
}

private struct ProjectExternalRefreshSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        @Bindable var store = store

        Section {
            Toggle(
                "Automatically refresh external changes",
                isOn: $store.automaticallyRefreshesExternalChanges
            )
        } header: {
            Text("External Changes")
        } footer: {
            Text(refreshExplanation)
        }
    }

    private var refreshExplanation: String {
        if project.projectEnvironment?.storageMode.refreshesWhenAppActivates == true {
            return "Reload server-backed Beads when Beadazzle becomes active. Local snapshot changes are always reloaded."
        }
        return "When Beads changes outside Beadazzle, export and reload its readable snapshot. Direct snapshot changes are always reloaded."
    }
}

private struct ProjectSnapshotSyncSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section {
            LabeledContent("Readable snapshot") {
                HStack(spacing: 8) {
                    ProjectHealthValueText(snapshotStatus)
                    if project.projectHealthSnapshot?.snapshotFile.exists == false {
                        ProjectHealthBadge(title: "Missing", style: .warning)
                    }
                }
            }

            ProjectHealthActionButton(
                title: "Export Snapshot",
                systemImage: "square.and.arrow.down",
                isDisabled: isBusy
            ) {
                Task { await store.exportProjectSnapshotNow() }
            }
        } header: {
            Text("Snapshot")
        } footer: {
            Text("Exports issue records to the readable JSONL snapshot used by Beadazzle. This is not a full database backup or cross-machine sync.")
        }
    }

    private var snapshotStatus: String? {
        guard let snapshot = project.projectHealthSnapshot?.snapshotFile else { return nil }
        return snapshot.exists ? "Present" : "Missing"
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }
}

private struct ProjectDoltSyncSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section {
            LabeledContent("Remotes") {
                if let remotes = project.projectHealthSnapshot?.doltRemotes.value {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(remotes.summary)
                        if remotes.firstReportedProblem != nil {
                            ProjectHealthBadge(title: "Check", style: .warning)
                        } else if remotes.remotes.isEmpty {
                            ProjectHealthBadge(title: "Local", style: .info)
                        }
                    }
                } else {
                    ProjectHealthConfigValueText(
                        nil,
                        errorMessage: project.projectHealthSnapshot?.doltRemotes.errorMessage
                    )
                }
            }

            LabeledContent("Automatic push") {
                if let config = project.projectHealthSnapshot?.storageConfig.value {
                    ProjectHealthConfigValueText(
                        config.doltAutoPushStatus.display { _ in config.doltAutoPushSummary },
                        errorMessage: config.doltAutoPushStatus.errorMessage
                    )
                } else {
                    ProjectHealthConfigValueText(
                        nil,
                        errorMessage: project.projectHealthSnapshot?.storageConfig.errorMessage
                    )
                }
            }

            if hasRemotes {
                HStack(spacing: 8) {
                    ProjectHealthActionButton(
                        title: "Pull from Remote",
                        systemImage: "arrow.down.circle",
                        isDisabled: isBusy
                    ) {
                        Task { await store.pullProjectIssues() }
                    }

                    ProjectHealthActionButton(
                        title: "Push to Remote",
                        systemImage: "arrow.up.circle",
                        isDisabled: isBusy
                    ) {
                        Task { await store.pushProjectIssues() }
                    }
                }
            }
        } header: {
            Text("Dolt Sync")
        } footer: {
            Text("Dolt remotes sync the Beads database and its history. They are separate from your project's Git commits.")
        }
    }

    private var hasRemotes: Bool {
        project.projectHealthSnapshot?.doltRemotes.value?.remotes.isEmpty == false
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }
}

private struct ProjectBackupSyncSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section {
            LabeledContent("Destination") {
                if let backup = project.projectHealthSnapshot?.backup.value {
                    ProjectHealthValueText(backup.dolt?.destinationSummary ?? "Not configured")
                } else {
                    ProjectHealthConfigValueText(
                        nil,
                        errorMessage: project.projectHealthSnapshot?.backup.errorMessage
                    )
                }
            }

            if let destination = project.projectHealthSnapshot?.backup.value?.dolt,
               destination.configured == true {
                LabeledContent("Last sync") {
                    ProjectHealthValueText(
                        destination.lastSyncDate.map(ProjectHealthFormatting.formattedDate)
                            ?? destination.lastSync,
                        placeholder: "Never"
                    )
                }
            }

            if isConfigured {
                ProjectHealthActionButton(
                    title: "Backup Now",
                    systemImage: "arrow.triangle.2.circlepath",
                    isDisabled: isBusy
                ) {
                    Task { await store.syncProjectBackup() }
                }
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("A Dolt-native backup preserves the full database, including tables, branches, history, and working-set data.")
        }
    }

    private var isConfigured: Bool {
        project.projectHealthSnapshot?.backup.value?.isConfigured == true
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }
}

private struct ProjectGitIntegrationSyncSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section {
            LabeledContent("Git integration") {
                ProjectHealthValueText(project.projectEnvironment?.gitIntegration.displayName)
            }

            LabeledContent("Hooks") {
                if project.projectHealthSnapshot?.storageConfig.value?.usesStealthMode == true {
                    HStack(spacing: 8) {
                        ProjectHealthValueText("Disabled")
                        ProjectHealthBadge(title: "Stealth", style: .info)
                    }
                } else if let hooks = project.projectHealthSnapshot?.hooks.value {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(hooks.summary)
                        if hooks.hasMissingHooks {
                            ProjectHealthBadge(title: "Optional", style: .info)
                        }
                    }
                } else {
                    ProjectHealthConfigValueText(
                        nil,
                        errorMessage: project.projectHealthSnapshot?.hooks.errorMessage
                    )
                }
            }

            if canInstallHooks {
                ProjectHealthActionButton(
                    title: "Install Hooks",
                    systemImage: "wrench.and.screwdriver",
                    isDisabled: isBusy
                ) {
                    Task { await store.installProjectHooks() }
                }
            }
        } header: {
            Text("Git Integration")
        }
    }

    private var canInstallHooks: Bool {
        project.projectHealthSnapshot?.hooks.value?.hasMissingHooks == true
            && project.projectEnvironment?.gitIntegration == .enabled
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }
}
