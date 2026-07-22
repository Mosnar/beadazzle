import SwiftUI

struct ProjectMaintenanceSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }

    var body: some View {
        Form {
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

            ProjectDatabaseMaintenanceSection()
        }
        .settingsGroupedForm()
        .loadsProjectHealthStatusIfNeeded()
    }
}

private struct ProjectDatabaseMaintenanceSection: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    @State private var pendingMaintenance: BeadsDoltMaintenanceKind?

    var body: some View {
        Section {
            LabeledContent("Database mode") {
                ProjectHealthValueText(project.projectHealthSnapshot?.context.value?.doltMode)
            }

            if let size = maintenance?.embeddedDatabaseSize {
                LabeledContent("Database size") {
                    Text(ProjectHealthFormatting.formattedBytes(size))
                        .monospacedDigit()
                }
            }

            if let compact = maintenance?.compact.value {
                LabeledContent("Beads history") {
                    Text("\(compact.totalCommits.formatted()) commits")
                        .monospacedDigit()
                }
                Text(compactionDescription(compact))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Compact Beads History…") {
                    pendingMaintenance = .compact
                }
                .disabled(isBusy || compact.oldCommits <= 1)
            } else if let error = maintenance?.compact.errorMessage {
                ProjectHealthMessageRow(
                    title: "Compaction unavailable",
                    message: error,
                    systemImage: "info.circle"
                )
            }

            if let flatten = maintenance?.flatten.value {
                Divider()
                Text("Flattening replaces the Beads database's \(flatten.commitCount.formatted())-commit history with one snapshot of its current data. It does not rewrite your project's Git history. Use it only when database growth is materially slowing writes and Beads-level history is no longer needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let tags = flatten.tags, !tags.isEmpty {
                    ProjectHealthMessageRow(
                        title: "Tagged history will remain",
                        message: "\(tags.count.formatted()) Dolt \(tags.count == 1 ? "tag points" : "tags point") to existing history. bd preserves tags, so garbage collection cannot reclaim the commits they retain.",
                        systemImage: "tag"
                    )
                }

                Button("Flatten Beads History…", role: .destructive) {
                    pendingMaintenance = .flatten
                }
                .disabled(isBusy || !flatten.wouldFlatten || flatten.commitCount <= 1)
            } else if let error = maintenance?.flatten.errorMessage {
                ProjectHealthMessageRow(
                    title: "Flattening unavailable",
                    message: error,
                    systemImage: "info.circle"
                )
            }
        } header: {
            Text("Beads Database Maintenance")
        } footer: {
            Text("Availability is checked with bd for this project's active database mode. A full backup is required unless you explicitly proceed without one; Beadazzle then exports a fresh JSONL snapshot and never auto-pushes rewritten Dolt history.")
        }
        .sheet(item: $pendingMaintenance) { kind in
            ProjectMaintenanceConfirmationSheet(kind: kind)
        }
    }

    private var maintenance: BeadsDoltMaintenancePreview? {
        project.projectHealthSnapshot?.maintenance
    }

    private var isBusy: Bool {
        project.isLoadingProjectHealth || project.projectHealthAction != nil
    }

    private func compactionDescription(_ compact: BeadsDoltCompactPreview) -> String {
        guard compact.oldCommits > 1 else {
            return "No compaction is needed: fewer than two Beads database commits are older than the \(compact.cutoffDays.formatted())-day retention window. This maintenance never rewrites your project's Git history."
        }
        return "Routine compaction squashes \(compact.oldCommits.formatted()) older commits in the Beads database into one base snapshot while preserving \(compact.recentCommits.formatted()) commits from the last \(compact.cutoffDays.formatted()) days. It does not rewrite your project's Git history."
    }
}

private struct ProjectMaintenanceConfirmationSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss
    let kind: BeadsDoltMaintenanceKind
    @State private var allowsProceedingWithoutBackup = false
    @State private var acknowledgesSharedHistoryCoordination = false
    @State private var isRunning = false
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: kind == .compact ? "shippingbox" : "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))

            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)

            if requiresSharedHistoryCoordination {
                Label(sharedHistoryExplanation, systemImage: "network")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    "Other writers are stopped and I understand the sync follow-up",
                    isOn: $acknowledgesSharedHistoryCoordination
                )
            }

            if !tagNames.isEmpty {
                Label(
                    "\(tagNames.count.formatted()) Dolt \(tagNames.count == 1 ? "tag preserves" : "tags preserve") old history, which limits how much storage garbage collection can reclaim.",
                    systemImage: "tag"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if backupIsConfigured {
                Label("Beadazzle will sync a full Dolt backup as a rollback point before changing history.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Toggle("Proceed if the backup sync fails", isOn: $allowsProceedingWithoutBackup)
                if kind == .flatten {
                    Text("Keep that rollback backup unchanged until the flattened database is verified. Reconfigure the backup before syncing it to the rewritten history.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("No configured backup was detected.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Toggle("Proceed without a current backup", isOn: $allowsProceedingWithoutBackup)
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Button(confirmTitle, role: .destructive) {
                    isRunning = true
                    failureMessage = nil
                    Task {
                        let succeeded = await store.performDoltMaintenance(
                            kind,
                            allowsProceedingWithoutBackup: allowsProceedingWithoutBackup
                        )
                        isRunning = false
                        if succeeded {
                            dismiss()
                        } else {
                            failureMessage = store.projectHealthActionError?.message
                                ?? "Database maintenance did not complete."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isRunning
                        || (!backupIsConfigured && !allowsProceedingWithoutBackup)
                        || (requiresSharedHistoryCoordination && !acknowledgesSharedHistoryCoordination)
                )
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled(isRunning)
    }

    private var backupIsConfigured: Bool {
        store.project.projectHealthSnapshot?.backup.value?.isConfigured == true
    }

    private var hasDoltRemote: Bool {
        if store.project.projectHealthSnapshot?.doltRemotes.value?.remotes.isEmpty == false {
            return true
        }
        return store.project.projectHealthSnapshot?.context.value?.syncRemote?.nilIfBlank != nil
    }

    private var usesServerStorage: Bool {
        guard let storageMode = store.project.projectEnvironment?.storageMode else { return false }
        return storageMode != .embedded
    }

    private var requiresSharedHistoryCoordination: Bool {
        hasDoltRemote || usesServerStorage
    }

    private var tagNames: [String] {
        store.project.projectHealthSnapshot?.maintenance.flatten.value?.tags ?? []
    }

    private var sharedHistoryExplanation: String {
        if hasDoltRemote {
            return "This rewrites shared Dolt history. Stop other writers and sync jobs first. Beadazzle will not auto-push the result; publish it deliberately with bd dolt push --force, then re-clone other copies before they resume syncing. An old copy can restore the history you removed."
        }
        return "This server-backed database may have other writers. Stop them before changing history, then verify the database before allowing writes to resume."
    }

    private var title: String {
        kind == .compact ? "Compact Beads History?" : "Flatten Beads History?"
    }

    private var confirmTitle: String {
        kind == .compact ? "Compact" : "Flatten History"
    }

    private var explanation: String {
        switch kind {
        case .compact:
            if let preview = store.project.projectHealthSnapshot?.maintenance.compact.value {
                return "This permanently squashes \(preview.oldCommits.formatted()) older commits in this project's Beads database into one base snapshot, preserves \(preview.recentCommits.formatted()) commits from the last \(preview.cutoffDays.formatted()) days, and then reclaims storage. Current bead data is preserved, and your project's Git commit history is not rewritten."
            }
            return "This permanently squashes older commits in this project's Beads database while preserving recent Beads history, then reclaims storage. Current bead data is preserved, and your project's Git commit history is not rewritten."
        case .flatten:
            let commitCount = store.project.projectHealthSnapshot?.maintenance.flatten.value?.commitCount
            let countDescription = commitCount.map { "its \($0.formatted()) commits" } ?? "its entire commit history"
            return "This permanently replaces \(countDescription) inside this project's Beads database with one snapshot, then reclaims storage. Current bead data is preserved, and your project's Git commit history is not rewritten. The Beads database history cannot be recovered without a backup."
        }
    }
}
