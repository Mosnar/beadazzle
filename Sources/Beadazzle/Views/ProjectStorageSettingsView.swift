import SwiftUI

struct ProjectStorageSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    @State private var expandedDetails: Set<ProjectStorageDetail> = []

    var body: some View {
        Form {
            ProjectStoragePreflightSection(
                preflight: ProjectPreflightHealth.evaluate(
                    projectURL: project.projectURL,
                    missingDataSourceURL: store.missingDataSourceURL,
                    activeDataSource: project.currentDataSource,
                    snapshotFreshness: project.snapshotFreshness,
                    health: project.projectHealthSnapshot,
                    automaticallyRefreshesExternalChanges: store.automaticallyRefreshesExternalChanges,
                    isLoading: project.isLoading || project.isLoadingProjectHealth || project.projectHealthSnapshot == nil
                )
            )

            ProjectStorageActionsSection(isInitialLoad: isInitialProjectHealthLoad)

            ProjectStorageWorkspaceSection()

            if !isInitialProjectHealthLoad {
                ProjectStorageOverviewSection()
                ProjectStorageRefreshSection()
                ProjectStorageDetailsSection(expandedDetails: $expandedDetails)
            }
        }
        .settingsGroupedForm()
        .task(id: project.projectURL) {
            store.loadProjectHealthStatus()
        }
        .onChange(of: project.projectURL) {
            expandedDetails.removeAll()
        }
    }

    private var isInitialProjectHealthLoad: Bool {
        project.isLoadingProjectHealth
            && project.projectHealthSnapshot == nil
            && project.projectHealthAction == nil
    }
}

private enum ProjectStorageDetail: Hashable {
    case database
    case snapshot
    case syncAndBackup
}

private struct ProjectStoragePreflightSection: View {
    let preflight: ProjectPreflightHealth
    @State private var isShowingOtherChecks = false

    private var presentation: ProjectHealthPresentation {
        ProjectHealthPresentation(preflight: preflight)
    }

    var body: some View {
        Section {
            ProjectPreflightSummaryView(
                preflight: preflight,
                badgeStatus: presentation.summaryBadgeStatus
            )

            ForEach(presentation.attentionChecks) { check in
                ProjectPreflightCheckRow(check: check)
            }

            if !presentation.otherChecks.isEmpty {
                SettingsDisclosure(
                    title: presentation.checksDisclosureTitle,
                    isExpanded: $isShowingOtherChecks
                ) {
                    ForEach(presentation.otherChecks) { check in
                        ProjectPreflightCheckRow(check: check)
                    }
                }
            }
        } header: {
            Text("Pre-flight")
        }
    }
}

private struct ProjectStorageActionsSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    let isInitialLoad: Bool

    var body: some View {
        Section("Actions") {
            VStack(alignment: .leading, spacing: 10) {
                ProjectHealthStatusSummary(
                    action: project.projectHealthAction,
                    isLoading: project.isLoadingProjectHealth,
                    loadedAt: project.projectHealthSnapshot?.loadedAt
                )

                if !isInitialLoad {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ProjectHealthActionButton(
                            title: "Refresh Status",
                            systemImage: "arrow.clockwise",
                            isDisabled: isBusy
                        ) {
                            store.loadProjectHealthStatus()
                        }

                        ProjectHealthActionButton(
                            title: "Export Snapshot",
                            systemImage: "square.and.arrow.down",
                            isDisabled: isBusy
                        ) {
                            Task { await store.exportProjectSnapshotNow() }
                        }

                        if project.projectHealthSnapshot?.hooks.value?.hasMissingHooks == true,
                           project.projectEnvironment?.gitIntegration == .enabled {
                            ProjectHealthActionButton(
                                title: "Install Hooks",
                                systemImage: "wrench.and.screwdriver",
                                isDisabled: isBusy
                            ) {
                                Task { await store.installProjectHooks() }
                            }
                        }

                        if project.projectHealthSnapshot?.backup.value?.isConfigured == true {
                            ProjectHealthActionButton(
                                title: "Backup Now",
                                systemImage: "arrow.triangle.2.circlepath",
                                isDisabled: isBusy
                            ) {
                                Task { await store.syncProjectBackup() }
                            }
                        }
                    }
                }

                if let actionError = project.projectHealthActionError {
                    ProjectHealthMessageRow(
                        title: "Last action failed",
                        message: actionError,
                        systemImage: "exclamationmark.triangle"
                    )
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }
}

private struct ProjectStorageWorkspaceSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var isConfirmingReset = false

    var body: some View {
        Section {
            Button("Reset Saved Workspace State", role: .destructive) {
                isConfirmingReset = true
            }
            .disabled(store.projectURL == nil)
        } header: {
            Text("Saved Workspace")
        } footer: {
            Text("Beadazzle remembers this project's last view, filters, sort, selection, and expansion on this Mac. Resetting returns it to defaults.")
        }
        .confirmationDialog(
            "Reset saved workspace state?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset", role: .destructive) {
                store.resetSavedWorkspaceState()
            }
        } message: {
            Text("The remembered view, filters, sort, selection, and expansion for this project will be cleared.")
        }
    }
}

private struct ProjectStorageOverviewSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section("Overview") {
            LabeledContent("Storage mode") {
                if let environment = project.projectEnvironment {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(environment.storageMode.displayName)
                        if environment.isRedirected {
                            ProjectHealthBadge(title: "Redirected", style: .info)
                        }
                        if environment.storageMode.refreshesWhenAppActivates {
                            ProjectHealthBadge(title: "Activation Refresh", style: .info)
                        }
                    }
                } else {
                    ProjectHealthConfigValueText(nil, errorMessage: project.projectHealthSnapshot?.context.errorMessage)
                }
            }

            LabeledContent("Git integration") {
                ProjectHealthValueText(project.projectEnvironment?.gitIntegration.displayName)
            }

            LabeledContent("Role") {
                if let environment = project.projectEnvironment {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(environment.role.displayName)
                        if environment.role == .contributor {
                            ProjectHealthBadge(title: "Routed", style: .info)
                                .help("bd routes new planning beads according to this checkout's contributor configuration.")
                        }
                    }
                } else {
                    ProjectHealthValueText(nil)
                }
            }

            LabeledContent("App reads") {
                if let source = project.projectHealthSnapshot?.snapshotFile.activeDataSource {
                    ProjectHealthValueText("JSONL snapshot")
                        .help(source.displayPath)
                } else {
                    ProjectHealthValueText(nil)
                }
            }

            LabeledContent("Freshness") {
                HStack(spacing: 8) {
                    ProjectHealthValueText(project.snapshotFreshness.message)
                    freshnessBadge
                }
                .help(project.snapshotFreshness.detail ?? project.snapshotFreshness.message)
            }

            LabeledContent("Git hooks") {
                if project.projectHealthSnapshot?.storageConfig.value?.usesStealthMode == true {
                    HStack(spacing: 8) {
                        ProjectHealthValueText("Disabled")
                        ProjectHealthBadge(title: "Stealth", style: .info)
                    }
                } else if let hooks = project.projectHealthSnapshot?.hooks.value {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(hooks.summary)
                        if hooks.hasMissingHooks {
                            ProjectHealthBadge(title: "Action", style: .warning)
                        }
                    }
                } else {
                    ProjectHealthConfigValueText(nil, errorMessage: project.projectHealthSnapshot?.hooks.errorMessage)
                }
            }

            LabeledContent("Backup") {
                if let backup = project.projectHealthSnapshot?.backup.value {
                    ProjectHealthValueText(backup.isConfigured ? "Configured" : "Not configured")
                } else {
                    ProjectHealthConfigValueText(nil, errorMessage: project.projectHealthSnapshot?.backup.errorMessage)
                }
            }
        }
    }

    @ViewBuilder
    private var freshnessBadge: some View {
        switch project.snapshotFreshness.state {
        case .current:
            EmptyView()
        case .refreshing:
            ProjectHealthBadge(title: "Refreshing", style: .info)
        case .possiblyStale:
            ProjectHealthBadge(title: "Check", style: .warning)
        case .unknown:
            ProjectHealthBadge(title: "Unknown", style: .info)
        }
    }
}

private struct ProjectStorageRefreshSection: View {
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
            Text("Automatic Refresh")
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

private struct ProjectStorageDetailsSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    @Binding var expandedDetails: Set<ProjectStorageDetail>

    var body: some View {
        Section("Details") {
            SettingsDisclosure(
                title: "Database Details",
                isExpanded: expansionBinding(for: .database)
            ) {
                databaseDetails
            }

            SettingsDisclosure(
                title: "Snapshot & Export Details",
                isExpanded: expansionBinding(for: .snapshot)
            ) {
                snapshotDetails
            }

            SettingsDisclosure(
                title: "Sync & Backup Details",
                isExpanded: expansionBinding(for: .syncAndBackup)
            ) {
                syncAndBackupDetails
            }
        }
    }

    @ViewBuilder
    private var databaseDetails: some View {
        if let context = project.projectHealthSnapshot?.context.value {
            SettingsDetailRow("bd Version") { ProjectHealthValueText(context.bdVersion) }
            SettingsDetailRow("Backend") { ProjectHealthValueText(context.backend) }
            SettingsDetailRow("Dolt Mode") { ProjectHealthValueText(context.doltMode) }
            SettingsDetailRow("Database") { ProjectHealthValueText(context.database) }
            if project.projectEnvironment?.storageMode == .embedded {
                SettingsDetailRow("Database Path") {
                    ProjectHealthPathText(
                        project.projectEnvironment?.beadsDirectoryURL
                            .appendingPathComponent("embeddeddolt", isDirectory: true)
                            .path
                    )
                }
            }
            SettingsDetailRow("Tracker Directory") {
                ProjectHealthPathText(project.projectEnvironment?.beadsDirectoryURL.path ?? context.beadsDirectory)
            }
            SettingsDetailRow("Redirected") {
                ProjectHealthValueText(ProjectHealthFormatting.formattedBool(project.projectEnvironment?.isRedirected))
            }
            SettingsDetailRow("Role") { ProjectHealthValueText(context.role) }
            SettingsDetailRow("Schema") { ProjectHealthValueText(context.schemaVersion.map(String.init)) }
            SettingsDetailRow("Project ID") { ProjectHealthPathText(context.projectID) }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.context.errorMessage)
        }
    }

    @ViewBuilder
    private var snapshotDetails: some View {
        let snapshotFile = project.projectHealthSnapshot?.snapshotFile

        SettingsDetailRow("JSONL Snapshot") {
            HStack(spacing: 8) {
                ProjectHealthValueText(snapshotFile?.exists == true ? "Present" : "Missing")
                if snapshotFile?.exists != true {
                    ProjectHealthBadge(title: "Missing", style: .warning)
                }
            }
        }
        SettingsDetailRow("Path") { ProjectHealthPathText(snapshotFile?.url.path) }
        SettingsDetailRow("Size") {
            ProjectHealthValueText(snapshotFile?.size.map(ProjectHealthFormatting.formattedBytes))
        }
        SettingsDetailRow("Modified") {
            ProjectHealthValueText(snapshotFile?.modifiedAt.map(ProjectHealthFormatting.formattedDate))
        }

        if let config = project.projectHealthSnapshot?.storageConfig.value {
            SettingsDetailRow("Export") {
                HStack(spacing: 8) {
                    ProjectHealthConfigValueText(
                        config.exportAutoStatus.display { _ in config.exportSummary },
                        errorMessage: config.exportAutoStatus.errorMessage
                    )
                    if !config.exportAutoStatus.isUnavailable, config.exportAuto == false {
                        ProjectHealthBadge(title: "Off", style: .warning)
                    }
                }
            }
            SettingsDetailRow("Export Path") {
                ProjectHealthConfigValueText(
                    config.exportPathStatus.display { $0 },
                    errorMessage: config.exportPathStatus.errorMessage
                )
            }
            SettingsDetailRow("Export Interval") {
                ProjectHealthConfigValueText(
                    config.exportIntervalStatus.display { $0 },
                    errorMessage: config.exportIntervalStatus.errorMessage
                )
            }
            SettingsDetailRow("Git Add Export") {
                if config.usesStealthMode {
                    ProjectHealthValueText("Disabled by stealth mode")
                } else {
                    ProjectHealthConfigValueText(
                        config.exportGitAddStatus.display { ProjectHealthFormatting.formattedBool($0) },
                        errorMessage: config.exportGitAddStatus.errorMessage
                    )
                }
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.storageConfig.errorMessage)
        }
    }

    @ViewBuilder
    private var syncAndBackupDetails: some View {
        if let config = project.projectHealthSnapshot?.storageConfig.value {
            SettingsDetailRow("JSONL Import") {
                ProjectHealthConfigValueText(
                    config.importAutoStatus.display { _ in config.importSummary },
                    errorMessage: config.importAutoStatus.errorMessage
                )
            }
            SettingsDetailRow("Federation Remote") {
                ProjectHealthConfigValueText(
                    config.federationRemoteStatus.display { _ in config.federationSummary },
                    errorMessage: config.federationRemoteStatus.errorMessage
                )
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.storageConfig.errorMessage)
        }

        if project.projectHealthSnapshot?.storageConfig.value?.usesStealthMode == true {
            SettingsDetailRow("Git Integration") {
                ProjectHealthValueText("Disabled by stealth mode")
            }
        } else if let hooks = project.projectHealthSnapshot?.hooks.value {
            if hooks.hasMissingHooks {
                SettingsDetailRow("Missing Hooks") {
                    ProjectHealthPathText(
                        hooks.missingHooks.map(\.name).joined(separator: ", "),
                        lineLimit: 3
                    )
                }
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.hooks.errorMessage)
        }

        if let backup = project.projectHealthSnapshot?.backup.value {
            SettingsDetailRow("Last Backup") {
                ProjectHealthValueText(
                    backup.lastBackupDate.map(ProjectHealthFormatting.formattedDate) ?? backup.backup?.timestamp
                )
            }
            SettingsDetailRow("Last Dolt Commit") { ProjectHealthPathText(backup.backup?.lastDoltCommit) }
            SettingsDetailRow("Destination") {
                ProjectHealthValueText(backup.isConfigured ? "Dolt remote" : "Not configured")
            }
            SettingsDetailRow("Database Size") {
                ProjectHealthValueText(backup.databaseSize?.displayValue, placeholder: "Not reported")
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.backup.errorMessage)
        }
    }

    private func expansionBinding(for detail: ProjectStorageDetail) -> Binding<Bool> {
        Binding(
            get: { expandedDetails.contains(detail) },
            set: { isExpanded in
                if isExpanded {
                    expandedDetails.insert(detail)
                } else {
                    expandedDetails.remove(detail)
                }
            }
        )
    }
}

private enum ProjectHealthFormatting {
    static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func formattedBool(_ value: Bool?) -> String? {
        value.map { $0 ? "Enabled" : "Disabled" }
    }
}
