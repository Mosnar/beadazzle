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
                ProjectStorageDisclosure(
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

                        if project.projectHealthSnapshot?.hooks.value?.hasMissingHooks == true {
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

private struct ProjectStorageOverviewSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Section("Overview") {
            LabeledContent("Source of truth") {
                if let context = project.projectHealthSnapshot?.context.value {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(context.usesCurrentEmbeddedDolt ? "Embedded Dolt" : context.storageSummary)
                        if !context.usesCurrentEmbeddedDolt {
                            ProjectHealthBadge(title: "Check", style: .warning)
                        }
                    }
                } else {
                    ProjectHealthConfigValueText(nil, errorMessage: project.projectHealthSnapshot?.context.errorMessage)
                }
            }

            LabeledContent("App reads") {
                if let source = project.projectHealthSnapshot?.snapshotFile.activeDataSource {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(source.kind == .jsonl ? "JSONL snapshot" : "SQLite snapshot")
                        if source.kind == .sqlite {
                            ProjectHealthBadge(title: "Legacy", style: .warning)
                        }
                    }
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
                if let hooks = project.projectHealthSnapshot?.hooks.value {
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
            Text("When Beads changes outside Beadazzle, export and reload its readable snapshot. Direct snapshot changes are always reloaded.")
        }
    }
}

private struct ProjectStorageDetailsSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    @Binding var expandedDetails: Set<ProjectStorageDetail>

    var body: some View {
        Section("Details") {
            ProjectStorageDisclosure(
                title: "Database Details",
                isExpanded: expansionBinding(for: .database)
            ) {
                databaseDetails
            }

            ProjectStorageDisclosure(
                title: "Snapshot & Export Details",
                isExpanded: expansionBinding(for: .snapshot)
            ) {
                snapshotDetails
            }

            ProjectStorageDisclosure(
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
            ProjectStorageDetailRow("bd Version") { ProjectHealthValueText(context.bdVersion) }
            ProjectStorageDetailRow("Backend") { ProjectHealthValueText(context.backend) }
            ProjectStorageDetailRow("Dolt Mode") { ProjectHealthValueText(context.doltMode) }
            ProjectStorageDetailRow("Database") { ProjectHealthValueText(context.database) }
            ProjectStorageDetailRow("Database Path") {
                ProjectHealthPathText(context.databasePath(projectURL: project.projectURL ?? URL(fileURLWithPath: "")))
            }
            ProjectStorageDetailRow("Role") { ProjectHealthValueText(context.role) }
            ProjectStorageDetailRow("Schema") { ProjectHealthValueText(context.schemaVersion.map(String.init)) }
            ProjectStorageDetailRow("Project ID") { ProjectHealthPathText(context.projectID) }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.context.errorMessage)
        }
    }

    @ViewBuilder
    private var snapshotDetails: some View {
        let snapshotFile = project.projectHealthSnapshot?.snapshotFile

        ProjectStorageDetailRow("JSONL Snapshot") {
            HStack(spacing: 8) {
                ProjectHealthValueText(snapshotFile?.exists == true ? "Present" : "Missing")
                if snapshotFile?.exists != true {
                    ProjectHealthBadge(title: "Missing", style: .warning)
                }
            }
        }
        ProjectStorageDetailRow("Path") { ProjectHealthPathText(snapshotFile?.url.path) }
        ProjectStorageDetailRow("Size") {
            ProjectHealthValueText(snapshotFile?.size.map(ProjectHealthFormatting.formattedBytes))
        }
        ProjectStorageDetailRow("Modified") {
            ProjectHealthValueText(snapshotFile?.modifiedAt.map(ProjectHealthFormatting.formattedDate))
        }

        if let config = project.projectHealthSnapshot?.storageConfig.value {
            ProjectStorageDetailRow("Export") {
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
            ProjectStorageDetailRow("Export Path") {
                ProjectHealthConfigValueText(
                    config.exportPathStatus.display { $0 },
                    errorMessage: config.exportPathStatus.errorMessage
                )
            }
            ProjectStorageDetailRow("Export Interval") {
                ProjectHealthConfigValueText(
                    config.exportIntervalStatus.display { $0 },
                    errorMessage: config.exportIntervalStatus.errorMessage
                )
            }
            ProjectStorageDetailRow("Git Add Export") {
                ProjectHealthConfigValueText(
                    config.exportGitAddStatus.display { ProjectHealthFormatting.formattedBool($0) },
                    errorMessage: config.exportGitAddStatus.errorMessage
                )
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.storageConfig.errorMessage)
        }
    }

    @ViewBuilder
    private var syncAndBackupDetails: some View {
        if let config = project.projectHealthSnapshot?.storageConfig.value {
            ProjectStorageDetailRow("JSONL Import") {
                ProjectHealthConfigValueText(
                    config.importAutoStatus.display { _ in config.importSummary },
                    errorMessage: config.importAutoStatus.errorMessage
                )
            }
            ProjectStorageDetailRow("Federation Remote") {
                ProjectHealthConfigValueText(
                    config.federationRemoteStatus.display { _ in config.federationSummary },
                    errorMessage: config.federationRemoteStatus.errorMessage
                )
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: project.projectHealthSnapshot?.storageConfig.errorMessage)
        }

        if let hooks = project.projectHealthSnapshot?.hooks.value {
            if hooks.hasMissingHooks {
                ProjectStorageDetailRow("Missing Hooks") {
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
            ProjectStorageDetailRow("Last Backup") {
                ProjectHealthValueText(
                    backup.lastBackupDate.map(ProjectHealthFormatting.formattedDate) ?? backup.backup?.timestamp
                )
            }
            ProjectStorageDetailRow("Last Dolt Commit") { ProjectHealthPathText(backup.backup?.lastDoltCommit) }
            ProjectStorageDetailRow("Destination") {
                ProjectHealthValueText(backup.isConfigured ? "Dolt remote" : "Not configured")
            }
            ProjectStorageDetailRow("Database Size") {
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

private struct ProjectStorageDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)

                    Text(title)
                        .fontWeight(.medium)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides details" : "Shows details")

            if isExpanded {
                Divider()
                    .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, 20)
                .padding(.bottom, 4)
            }
        }
    }
}

private struct ProjectStorageDetailRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: () -> Value

    init(_ title: String, @ViewBuilder value: @escaping () -> Value) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            value()
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
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
