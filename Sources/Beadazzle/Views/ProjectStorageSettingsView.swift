import SwiftUI

struct ProjectStorageSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        Form {
            preflightSection
            actionsSection

            if let actionError = store.projectHealthActionError {
                Section("Last Action") {
                    ProjectHealthMessageRow(
                        title: "Error",
                        message: actionError,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            if !isInitialProjectHealthLoad {
                storageSection
                snapshotSection
                syncSection
                backupSection
            }
        }
        .settingsGroupedForm()
        .task(id: store.projectURL) {
            store.loadProjectHealthStatus()
        }
    }

    private var preflightSection: some View {
        Section("Pre-flight") {
            let preflight = ProjectPreflightHealth.evaluate(
                projectURL: store.projectURL,
                missingDataSourceURL: store.missingDataSourceURL,
                activeDataSource: store.currentDataSource,
                snapshotFreshness: store.snapshotFreshness,
                health: store.projectHealthSnapshot,
                automaticallyRefreshesExternalChanges: store.automaticallyRefreshesExternalChanges,
                isLoading: store.isLoading || store.isLoadingProjectHealth || store.projectHealthSnapshot == nil
            )

            ProjectPreflightSummaryView(preflight: preflight)

            ForEach(preflight.checks) { check in
                ProjectPreflightCheckRow(check: check)
            }
        }
    }

    private var actionsSection: some View {
        Section("Status") {
            VStack(alignment: .leading, spacing: 10) {
                ProjectHealthStatusSummary(
                    action: store.projectHealthAction,
                    isLoading: store.isLoadingProjectHealth,
                    loadedAt: store.projectHealthSnapshot?.loadedAt
                )

                if !isInitialProjectHealthLoad {
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
                            Task {
                                await store.exportProjectSnapshotNow()
                            }
                        }

                        if store.projectHealthSnapshot?.hooks.value?.hasMissingHooks == true {
                            ProjectHealthActionButton(
                                title: "Install Hooks",
                                systemImage: "wrench.and.screwdriver",
                                isDisabled: isBusy
                            ) {
                                Task {
                                    await store.installProjectHooks()
                                }
                            }
                        }

                        if store.projectHealthSnapshot?.backup.value?.isConfigured == true {
                            ProjectHealthActionButton(
                                title: "Backup Now",
                                systemImage: "arrow.triangle.2.circlepath",
                                isDisabled: isBusy
                            ) {
                                Task {
                                    await store.syncProjectBackup()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            if let context = store.projectHealthSnapshot?.context.value {
                LabeledContent("Source of truth") {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(context.usesCurrentEmbeddedDolt ? "Embedded Dolt" : context.storageSummary)
                        ProjectHealthBadge(
                            title: context.usesCurrentEmbeddedDolt ? "Current" : "Check",
                            style: context.usesCurrentEmbeddedDolt ? .ok : .warning
                        )
                    }
                }
                LabeledContent("bd Version") {
                    ProjectHealthValueText(context.bdVersion)
                }
                LabeledContent("Backend") {
                    ProjectHealthValueText(context.backend)
                }
                LabeledContent("Dolt Mode") {
                    ProjectHealthValueText(context.doltMode)
                }
                LabeledContent("Database") {
                    ProjectHealthValueText(context.database)
                }
                LabeledContent("Database Path") {
                    ProjectHealthPathText(context.databasePath(projectURL: store.projectURL ?? URL(fileURLWithPath: "")))
                }
                LabeledContent("Role") {
                    ProjectHealthValueText(context.role)
                }
                LabeledContent("Schema") {
                    ProjectHealthValueText(context.schemaVersion.map(String.init))
                }
                LabeledContent("Project ID") {
                    ProjectHealthPathText(context.projectID)
                }
            } else {
                ProjectHealthUnavailableRow(errorMessage: store.projectHealthSnapshot?.context.errorMessage)
            }
        }
    }

    private var snapshotSection: some View {
        @Bindable var store = store

        return Section("Beadazzle Snapshot") {
            let snapshotFile = store.projectHealthSnapshot?.snapshotFile

            Toggle(
                "Automatically refresh external changes",
                isOn: $store.automaticallyRefreshesExternalChanges
            )
            Text("When Beads changes outside Beadazzle, export and reload its readable snapshot. Direct snapshot changes are always reloaded.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("App Reads") {
                if let source = snapshotFile?.activeDataSource {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(source.kind == .jsonl ? "JSONL snapshot" : "SQLite snapshot")
                        ProjectHealthBadge(
                            title: source.kind == .jsonl ? "Current" : "Legacy",
                            style: source.kind == .jsonl ? .ok : .warning
                        )
                    }
                } else {
                    ProjectHealthValueText(nil)
                }
            }
            LabeledContent("JSONL Snapshot") {
                HStack(spacing: 8) {
                    ProjectHealthValueText(snapshotFile?.exists == true ? "Present" : "Missing")
                    ProjectHealthBadge(
                        title: snapshotFile?.exists == true ? "Ready" : "Missing",
                        style: snapshotFile?.exists == true ? .ok : .warning
                    )
                }
            }
            LabeledContent("Freshness") {
                HStack(spacing: 8) {
                    ProjectHealthValueText(store.snapshotFreshness.message)
                    ProjectHealthBadge(
                        title: freshnessBadgeTitle,
                        style: freshnessBadgeStyle
                    )
                }
                .help(store.snapshotFreshness.detail ?? store.snapshotFreshness.message)
            }
            LabeledContent("Path") {
                ProjectHealthPathText(snapshotFile?.url.path)
            }
            LabeledContent("Size") {
                ProjectHealthValueText(snapshotFile?.size.map(Self.formattedBytes))
            }
            LabeledContent("Modified") {
                ProjectHealthValueText(snapshotFile?.modifiedAt.map(Self.formattedDate))
            }

            if let config = store.projectHealthSnapshot?.storageConfig.value {
                LabeledContent("Export") {
                    HStack(spacing: 8) {
                        ProjectHealthConfigValueText(
                            config.exportAutoStatus.display { _ in config.exportSummary },
                            errorMessage: config.exportAutoStatus.errorMessage
                        )
                        if !config.exportAutoStatus.isUnavailable {
                            ProjectHealthBadge(
                                title: config.exportAuto == false ? "Off" : "On",
                                style: config.exportAuto == false ? .warning : .ok
                            )
                        }
                    }
                }
                LabeledContent("Export Path") {
                    ProjectHealthConfigValueText(
                        config.exportPathStatus.display { $0 },
                        errorMessage: config.exportPathStatus.errorMessage
                    )
                }
                LabeledContent("Export Interval") {
                    ProjectHealthConfigValueText(
                        config.exportIntervalStatus.display { $0 },
                        errorMessage: config.exportIntervalStatus.errorMessage
                    )
                }
                LabeledContent("Git Add Export") {
                    ProjectHealthConfigValueText(
                        config.exportGitAddStatus.display { Self.formattedBool($0) },
                        errorMessage: config.exportGitAddStatus.errorMessage
                    )
                }
            } else {
                ProjectHealthUnavailableRow(errorMessage: store.projectHealthSnapshot?.storageConfig.errorMessage)
            }
        }
    }

    private var syncSection: some View {
        Section("Sync Model") {
            if let config = store.projectHealthSnapshot?.storageConfig.value {
                LabeledContent("JSONL Import") {
                    HStack(spacing: 8) {
                        ProjectHealthConfigValueText(
                            config.importAutoStatus.display { _ in config.importSummary },
                            errorMessage: config.importAutoStatus.errorMessage
                        )
                        if !config.importAutoStatus.isUnavailable {
                            ProjectHealthBadge(
                                title: config.importAuto == true ? "Auto" : "Manual",
                                style: .info
                            )
                        }
                    }
                }
                LabeledContent("Federation Remote") {
                    HStack(spacing: 8) {
                        ProjectHealthConfigValueText(
                            config.federationRemoteStatus.display { _ in config.federationSummary },
                            errorMessage: config.federationRemoteStatus.errorMessage
                        )
                        if !config.federationRemoteStatus.isUnavailable {
                            ProjectHealthBadge(
                                title: config.federationRemote?.nilIfBlank == nil ? "Optional" : "Configured",
                                style: .info
                            )
                        }
                    }
                }
            } else {
                ProjectHealthUnavailableRow(errorMessage: store.projectHealthSnapshot?.storageConfig.errorMessage)
            }

            if let hooks = store.projectHealthSnapshot?.hooks.value {
                LabeledContent("Git Hooks") {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(hooks.summary)
                        ProjectHealthBadge(
                            title: hooks.hasMissingHooks ? "Action" : "Ready",
                            style: hooks.hasMissingHooks ? .warning : .ok
                        )
                    }
                }
                if hooks.hasMissingHooks {
                    LabeledContent("Missing Hooks") {
                        ProjectHealthPathText(hooks.missingHooks.map(\.name).joined(separator: ", "))
                    }
                }
            } else {
                ProjectHealthUnavailableRow(errorMessage: store.projectHealthSnapshot?.hooks.errorMessage)
            }
        }
    }

    private var backupSection: some View {
        Section("Backup") {
            if let backup = store.projectHealthSnapshot?.backup.value {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(backup.isConfigured ? "Configured" : "Not configured")
                        ProjectHealthBadge(
                            title: backup.isConfigured ? "Ready" : "Optional",
                            style: backup.isConfigured ? .ok : .info
                        )
                    }
                }
                LabeledContent("Last Backup") {
                    ProjectHealthValueText(backup.lastBackupDate.map(Self.formattedDate) ?? backup.backup?.timestamp)
                }
                LabeledContent("Last Dolt Commit") {
                    ProjectHealthPathText(backup.backup?.lastDoltCommit)
                }
                LabeledContent("Destination") {
                    HStack(spacing: 8) {
                        ProjectHealthValueText(backup.isConfigured ? "Dolt remote" : "Not configured")
                        ProjectHealthBadge(
                            title: backup.isConfigured ? "Remote" : "Optional",
                            style: .info
                        )
                    }
                }
                LabeledContent("Database Size") {
                    ProjectHealthValueText(backup.databaseSize?.displayValue, placeholder: "Not reported")
                }
            } else {
                ProjectHealthUnavailableRow(errorMessage: store.projectHealthSnapshot?.backup.errorMessage)
            }
        }
    }

    private var isBusy: Bool {
        store.isLoadingProjectHealth || store.projectHealthAction != nil
    }

    private var isInitialProjectHealthLoad: Bool {
        store.isLoadingProjectHealth
            && store.projectHealthSnapshot == nil
            && store.projectHealthAction == nil
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func formattedBool(_ value: Bool?) -> String? {
        value.map { $0 ? "Enabled" : "Disabled" }
    }

    private var freshnessBadgeTitle: String {
        switch store.snapshotFreshness.state {
        case .current:
            "Current"
        case .refreshing:
            "Refreshing"
        case .possiblyStale:
            "Check"
        case .unknown:
            "Unknown"
        }
    }

    private var freshnessBadgeStyle: ProjectHealthBadge.Style {
        switch store.snapshotFreshness.state {
        case .current:
            .ok
        case .refreshing, .unknown:
            .info
        case .possiblyStale:
            .warning
        }
    }
}

private struct ProjectPreflightSummaryView: View {
    let preflight: ProjectPreflightHealth

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: preflight.status.systemImage)
                .font(.title3)
                .foregroundStyle(preflight.status.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(preflight.title)
                    .font(.headline)
                Text(preflight.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ProjectHealthBadge(
                title: preflight.status.badgeTitle,
                style: preflight.status.badgeStyle
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preflight.title)
        .accessibilityValue(preflight.summary)
    }
}

private struct ProjectPreflightCheckRow: View {
    let check: ProjectPreflightHealth.Check

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(check.status.tint)
                .frame(width: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(check.title)
                        .font(.callout.weight(.semibold))
                    Text(check.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                if let detail = check.detail?.nilIfBlank {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if let actionHint = check.actionHint?.nilIfBlank {
                    Label(actionHint, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(check.status.tint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.title), \(check.status.accessibilityLabel)")
        .accessibilityValue(check.summary)
        .accessibilityHint([check.detail, check.actionHint].compactMap { $0?.nilIfBlank }.joined(separator: " "))
    }
}

private struct ProjectHealthStatusSummary: View {
    let action: ProjectHealthAction?
    let isLoading: Bool
    let loadedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            content
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var content: some View {
        if let action {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(action.title)
            }
        } else if isLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading status")
            }
        } else if let loadedAt {
            Label("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
        } else {
            Label("Status not loaded", systemImage: "clock")
        }
    }
}

private struct ProjectHealthActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .help(title)
    }
}

private struct ProjectHealthValueText: View {
    let value: String?
    let placeholder: String

    init(_ value: String?, placeholder: String = "Unavailable") {
        self.value = value?.nilIfBlank
        self.placeholder = placeholder
    }

    var body: some View {
        Text(value ?? placeholder)
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(1)
    }
}

private struct ProjectHealthConfigValueText: View {
    let value: String?
    let errorMessage: String?

    init(_ value: String?, errorMessage: String?) {
        self.value = value
        self.errorMessage = errorMessage
    }

    var body: some View {
        ProjectHealthValueText(errorMessage == nil ? value : nil)
            .help(errorMessage ?? value ?? "Unavailable")
    }
}

private struct ProjectHealthPathText: View {
    let value: String?

    init(_ value: String?) {
        self.value = value?.nilIfBlank
    }

    var body: some View {
        Text(value ?? "Unavailable")
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(value ?? "Unavailable")
    }
}

private struct ProjectHealthUnavailableRow: View {
    let errorMessage: String?

    var body: some View {
        ProjectHealthMessageRow(
            title: "Unavailable",
            message: errorMessage ?? "Status has not loaded yet.",
            systemImage: "exclamationmark.triangle"
        )
    }
}

private struct ProjectHealthMessageRow: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProjectHealthBadge: View {
    enum Style {
        case ok
        case info
        case warning
        case critical
    }

    let title: String
    let style: Style

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(backgroundStyle, in: Capsule())
            .accessibilityLabel(title)
    }

    private var foregroundStyle: Color {
        switch style {
        case .ok:
            Color.green
        case .info:
            Color.accentColor
        case .warning:
            Color.orange
        case .critical:
            Color.red
        }
    }

    private var backgroundStyle: Color {
        foregroundStyle.opacity(0.14)
    }
}

private extension ProjectPreflightHealth.Status {
    var systemImage: String {
        switch self {
        case .ready:
            "checkmark.circle.fill"
        case .info:
            "info.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .blocked:
            "xmark.octagon.fill"
        case .checking:
            "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            .green
        case .info:
            .accentColor
        case .warning:
            .orange
        case .blocked:
            .red
        case .checking:
            .secondary
        }
    }

    var badgeTitle: String {
        switch self {
        case .ready:
            "Ready"
        case .info:
            "Info"
        case .warning:
            "Check"
        case .blocked:
            "Blocked"
        case .checking:
            "Checking"
        }
    }

    var badgeStyle: ProjectHealthBadge.Style {
        switch self {
        case .ready:
            .ok
        case .info, .checking:
            .info
        case .warning:
            .warning
        case .blocked:
            .critical
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ready:
            "ready"
        case .info:
            "informational"
        case .warning:
            "needs attention"
        case .blocked:
            "blocked"
        case .checking:
            "checking"
        }
    }
}
