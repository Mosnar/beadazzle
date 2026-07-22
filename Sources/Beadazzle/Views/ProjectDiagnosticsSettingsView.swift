import SwiftUI

struct ProjectDiagnosticsSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    @State private var expandedDetails: Set<ProjectDiagnosticDetail> = []

    var body: some View {
        Form {
            Section("Status") {
                ProjectHealthStatusSummary(
                    action: project.projectHealthAction,
                    isLoading: project.isLoadingProjectHealth,
                    loadedAt: project.projectHealthSnapshot?.loadedAt
                )

                ProjectHealthActionButton(
                    title: "Refresh Status",
                    systemImage: "arrow.clockwise",
                    isDisabled: isBusy
                ) {
                    store.loadProjectHealthStatus()
                }

                if let actionError = project.projectHealthActionError {
                    ProjectHealthMessageRow(
                        title: actionError.title,
                        message: actionError.message,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            ProjectDiagnosticDetailsSection(expandedDetails: $expandedDetails)
        }
        .settingsGroupedForm()
        .loadsProjectHealthStatusIfNeeded()
        .onChange(of: project.projectURL) {
            expandedDetails.removeAll()
        }
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }
}

private enum ProjectDiagnosticDetail: Hashable {
    case database
    case doltSync
    case snapshot
    case backup
    case gitIntegration
}

private struct ProjectDiagnosticDetailsSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    @Binding var expandedDetails: Set<ProjectDiagnosticDetail>

    var body: some View {
        Section("Technical Details") {
            SettingsDisclosure(
                title: "Database",
                isExpanded: expansionBinding(for: .database)
            ) {
                databaseDetails
            }

            SettingsDisclosure(
                title: "Dolt Sync",
                isExpanded: expansionBinding(for: .doltSync)
            ) {
                ProjectStorageDoltSyncDetails(
                    context: project.projectHealthSnapshot?.context.value,
                    remotes: project.projectHealthSnapshot?.doltRemotes,
                    storageConfig: project.projectHealthSnapshot?.storageConfig
                )
            }

            SettingsDisclosure(
                title: "Snapshot & Export",
                isExpanded: expansionBinding(for: .snapshot)
            ) {
                snapshotDetails
            }

            SettingsDisclosure(
                title: "Backup",
                isExpanded: expansionBinding(for: .backup)
            ) {
                ProjectStorageBackupDetails(backup: project.projectHealthSnapshot?.backup)
            }

            SettingsDisclosure(
                title: "Git Integration",
                isExpanded: expansionBinding(for: .gitIntegration)
            ) {
                ProjectStorageGitIntegrationDetails(
                    storageConfig: project.projectHealthSnapshot?.storageConfig,
                    hooks: project.projectHealthSnapshot?.hooks
                )
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
                ProjectHealthPathText(
                    project.projectEnvironment?.beadsDirectoryURL.path ?? context.beadsDirectory
                )
            }
            SettingsDetailRow("Redirected") {
                ProjectHealthValueText(
                    ProjectHealthFormatting.formattedBool(project.projectEnvironment?.isRedirected)
                )
            }
            SettingsDetailRow("Role") { ProjectHealthValueText(context.role) }
            SettingsDetailRow("Schema") {
                ProjectHealthValueText(context.schemaVersion.map(String.init))
            }
            SettingsDetailRow("Project ID") { ProjectHealthPathText(context.projectID) }
        } else {
            ProjectHealthUnavailableRow(
                errorMessage: project.projectHealthSnapshot?.context.errorMessage
            )
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
                        config.exportGitAddStatus.display {
                            ProjectHealthFormatting.formattedBool($0)
                        },
                        errorMessage: config.exportGitAddStatus.errorMessage
                    )
                }
            }
            SettingsDetailRow("Legacy JSONL Fallback") {
                ProjectHealthConfigValueText(
                    config.importAutoStatus.display { _ in config.importSummary },
                    errorMessage: config.importAutoStatus.errorMessage
                )
            }
        } else {
            ProjectHealthUnavailableRow(
                errorMessage: project.projectHealthSnapshot?.storageConfig.errorMessage
            )
        }
    }

    private func expansionBinding(for detail: ProjectDiagnosticDetail) -> Binding<Bool> {
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
