import SwiftUI

struct ProjectStorageDoltSyncDetails: View {
    let context: BeadsProjectContext?
    let remotes: ProjectHealthValue<BeadsDoltRemotes>?
    let storageConfig: ProjectHealthValue<ProjectStorageConfig>?

    var body: some View {
        if let remoteStatus = remotes?.value {
            if remoteStatus.remotes.isEmpty {
                SettingsDetailRow("Remote") {
                    ProjectHealthValueText("Not configured")
                }
                if let declaredRemote = context?.syncRemote?.nilIfBlank {
                    SettingsDetailRow("Declared Remote") {
                        HStack(spacing: 8) {
                            ProjectHealthPathText(declaredRemote)
                            ProjectHealthBadge(title: "Not registered", style: .warning)
                        }
                    }
                }
            } else {
                ForEach(remoteStatus.remotes) { remote in
                    ProjectDoltRemoteDetailRow(remote: remote)
                }
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: remotes?.errorMessage)
        }

        if let config = storageConfig?.value {
            SettingsDetailRow("Automatic Push") {
                HStack(spacing: 8) {
                    ProjectHealthConfigValueText(
                        config.doltAutoPushStatus.display { _ in config.doltAutoPushSummary },
                        errorMessage: config.doltAutoPushStatus.errorMessage
                    )
                    if config.doltAutoPushStatus.errorMessage == nil, config.doltAutoPush != true {
                        ProjectHealthBadge(title: "Off", style: .info)
                    } else if config.doltAutoPush == true {
                        ProjectHealthBadge(title: "Single writer", style: .info)
                            .help("Beads recommends automatic push only for single-writer projects.")
                    }
                }
            }
            SettingsDetailRow("Push Interval") {
                ProjectHealthConfigValueText(
                    config.doltAutoPushIntervalStatus.display { $0 ?? "5m (default)" },
                    errorMessage: config.doltAutoPushIntervalStatus.errorMessage
                )
            }
            SettingsDetailRow("Push Timeout") {
                ProjectHealthConfigValueText(
                    config.doltAutoPushTimeoutStatus.display { $0 ?? "30s (default)" },
                    errorMessage: config.doltAutoPushTimeoutStatus.errorMessage
                )
            }
            SettingsDetailRow("Federation Peer") {
                ProjectHealthConfigValueText(
                    config.federationRemoteStatus.display { _ in config.federationSummary },
                    errorMessage: config.federationRemoteStatus.errorMessage
                )
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: storageConfig?.errorMessage)
        }
    }
}

private struct ProjectDoltRemoteDetailRow: View {
    let remote: BeadsDoltRemote

    var body: some View {
        SettingsDetailRow("Remote \(remote.name)") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProjectHealthValueText(remote.status ?? "Configured")
                    if remote.hasReportedProblem {
                        ProjectHealthBadge(title: "Check", style: .warning)
                    } else {
                        ProjectHealthBadge(title: "Ready", style: .ok)
                    }
                }
                ProjectHealthPathText(remote.url, lineLimit: 2)
            }
        }
    }
}

struct ProjectStorageBackupDetails: View {
    let backup: ProjectHealthValue<BeadsBackupStatus>?

    var body: some View {
        if let backup = backup?.value {
            SettingsDetailRow("Destination") {
                ProjectHealthValueText(backup.dolt?.destinationSummary ?? "Not configured")
            }
            if let destination = backup.dolt, destination.configured == true {
                SettingsDetailRow("Backup Name") {
                    ProjectHealthValueText(destination.backupName)
                }
                SettingsDetailRow("Backup URL") {
                    ProjectHealthPathText(destination.backupURL, lineLimit: 2)
                }
                SettingsDetailRow("Last Sync") {
                    ProjectHealthValueText(
                        destination.lastSyncDate.map(ProjectHealthFormatting.formattedDate)
                            ?? destination.lastSync
                    )
                }
                SettingsDetailRow("Sync Duration") {
                    ProjectHealthValueText(destination.syncDuration)
                }
            }
            SettingsDetailRow("Last Backup") {
                ProjectHealthValueText(
                    backup.lastBackupDate.map(ProjectHealthFormatting.formattedDate) ?? backup.backup?.timestamp
                )
            }
            SettingsDetailRow("Last Dolt Commit") {
                ProjectHealthPathText(backup.backup?.lastDoltCommit)
            }
            SettingsDetailRow("Database Size") {
                ProjectHealthValueText(backup.databaseSize?.displayValue, placeholder: "Not reported")
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: backup?.errorMessage)
        }
    }
}

struct ProjectStorageGitIntegrationDetails: View {
    let storageConfig: ProjectHealthValue<ProjectStorageConfig>?
    let hooks: ProjectHealthValue<BeadsHooksStatus>?

    var body: some View {
        if storageConfig?.value?.usesStealthMode == true {
            SettingsDetailRow("Git Integration") {
                ProjectHealthValueText("Disabled by stealth mode")
            }
        } else if let hooks = hooks?.value {
            SettingsDetailRow("Git Hooks") {
                HStack(spacing: 8) {
                    ProjectHealthValueText(hooks.summary)
                    if hooks.hasMissingHooks {
                        ProjectHealthBadge(title: "Optional", style: .info)
                    }
                }
            }
            if hooks.hasMissingHooks {
                SettingsDetailRow("Missing Hooks") {
                    ProjectHealthPathText(
                        hooks.missingHooks.map(\.name).joined(separator: ", "),
                        lineLimit: 3
                    )
                }
            }
        } else {
            ProjectHealthUnavailableRow(errorMessage: hooks?.errorMessage)
        }
    }
}
