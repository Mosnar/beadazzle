import SwiftUI

struct ProjectOverviewSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Form {
            ProjectOverviewPreflightSection(preflight: preflight)

            if !isInitialProjectHealthLoad {
                ProjectOverviewSummarySection()
            }
        }
        .settingsGroupedForm()
        .loadsProjectHealthStatusIfNeeded()
    }

    private var preflight: ProjectPreflightHealth {
        ProjectPreflightHealth.evaluate(
            projectURL: project.projectURL,
            missingDataSourceURL: store.missingDataSourceURL,
            activeDataSource: project.currentDataSource,
            snapshotFreshness: project.snapshotFreshness,
            health: project.projectHealthSnapshot,
            automaticallyRefreshesExternalChanges: store.automaticallyRefreshesExternalChanges,
            isLoading: project.isLoading || project.isLoadingProjectHealth || project.projectHealthSnapshot == nil
        )
    }

    private var isInitialProjectHealthLoad: Bool {
        project.isLoadingProjectHealth
            && project.projectHealthSnapshot == nil
            && project.projectHealthAction == nil
    }
}

private struct ProjectOverviewPreflightSection: View {
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
            Text("Project Health")
        }
    }
}

private struct ProjectOverviewSummarySection: View {
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
                    ProjectHealthConfigValueText(
                        nil,
                        errorMessage: project.projectHealthSnapshot?.context.errorMessage
                    )
                }
            }

            LabeledContent("Freshness") {
                HStack(spacing: 8) {
                    ProjectHealthValueText(project.snapshotFreshness.message)
                    freshnessBadge
                }
                .help(project.snapshotFreshness.detail ?? project.snapshotFreshness.message)
            }

            LabeledContent("Dolt sync") {
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

            LabeledContent("Backup") {
                if let backup = project.projectHealthSnapshot?.backup.value {
                    ProjectHealthValueText(backup.isConfigured ? "Configured" : "Not configured")
                } else {
                    ProjectHealthConfigValueText(
                        nil,
                        errorMessage: project.projectHealthSnapshot?.backup.errorMessage
                    )
                }
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

enum ProjectHealthFormatting {
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
