import SwiftUI

/// Compact access to Dolt synchronization. The primary action pulls and pushes the
/// authoritative database, then refreshes Beadazzle's readable snapshot; the menu keeps
/// explicit directional commands available for recovery and advanced workflows.
struct ProjectDoltSyncMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var presentedFailureOutcome: ProjectDoltSyncOutcome?
    private var project: BeadProjectStore { store.project }
    let title: String
    let reportsFailureInWorkspace: Bool
    let fillsAvailableWidth: Bool
    let isExternallyDisabled: Bool
    let completionRefresh: ProjectHealthCompletionRefresh

    init(
        title: String = "Sync",
        reportsFailureInWorkspace: Bool = true,
        fillsAvailableWidth: Bool = false,
        isExternallyDisabled: Bool = false,
        completionRefresh: ProjectHealthCompletionRefresh = .none
    ) {
        self.title = title
        self.reportsFailureInWorkspace = reportsFailureInWorkspace
        self.fillsAvailableWidth = fillsAvailableWidth
        self.isExternallyDisabled = isExternallyDisabled
        self.completionRefresh = completionRefresh
    }

    var body: some View {
        menuControl
            .disabled(isMenuDisabled)
            .help(syncHelp)
            .accessibilityLabel(activeSyncAction?.title ?? accessibilityLabel)
            .accessibilityHint(activeSyncAction == nil ? syncHelp : "Open Sync status")
            .sheet(item: $presentedFailureOutcome) { outcome in
                ProjectDoltSyncFailureDetailsSheet(outcome: outcome)
            }
    }

    @ViewBuilder
    private var menuControl: some View {
        if activeSyncAction != nil {
            Menu {
                menuContent
            } label: {
                menuLabel
            }
        } else {
            Menu {
                menuContent
            } label: {
                menuLabel
            } primaryAction: {
                performSync()
            }
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        syncButton(.pull)
        syncButton(.push)

        Divider()

        Button(
            store.doltRemoteFreshness.isChecking
                ? "Checking for Remote Changes…"
                : "Check for Remote Changes",
            systemImage: "arrow.clockwise"
        ) {
            store.checkProjectDoltRemoteFreshness(.manual)
        }
        .disabled(
            activeSyncAction != nil
                || store.doltRemoteFreshness.isChecking
                || !store.doltRemoteFreshness.result.canCheckAgain
        )
        .help(remoteStatusDetail)

        if let activeSyncAction {
            Text("\(project.projectDoltSyncPhase?.title ?? activeSyncAction.title)…")
        } else {
            if let outcome = project.projectDoltSyncOutcome {
                if outcome.hasCommandDetails {
                    Button(
                        "\(outcome.title)…",
                        systemImage: outcomeSystemImage(outcome.result)
                    ) {
                        presentedFailureOutcome = outcome
                    }
                    .help("Show the complete selectable command output")
                } else {
                    Label(
                        outcome.title,
                        systemImage: outcomeSystemImage(outcome.result)
                    )
                    .help(outcome.detail)
                }
            }
            Text(remoteStatusSummary)
                .help(remoteStatusDetail)
            if store.doltRemoteFreshness.result.requiresSyncCheckpoint {
                Text("Sync once to enable remote change checks")
            }
        }
    }

    private var menuLabel: some View {
        Label {
            Text(title)
        } icon: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .overlay(alignment: .topTrailing) {
                        if store.doltRemoteFreshness.result.hasRemoteChanges {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -3)
                                .accessibilityHidden(true)
                        }
                    }
                if activeSyncAction != nil || store.doltRemoteFreshness.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
    }

    private var activeSyncAction: ProjectHealthAction? {
        project.projectHealthAction?.isDoltSync == true ? project.projectHealthAction : nil
    }

    private var isMenuDisabled: Bool {
        isExternallyDisabled
            || (!store.canSynchronizeProjectIssues && activeSyncAction == nil)
    }

    private var syncHelp: String {
        if store.isLoadingProjectDoltRemotes {
            return "Checking this project for a Dolt remote"
        }
        if let activeSyncAction {
            guard let phase = project.projectDoltSyncPhase else { return activeSyncAction.title }
            return [phase.title, phase.command, phase.detail]
                .compactMap(\.self)
                .joined(separator: ". ")
        }
        if store.doltRemoteFreshness.isChecking { return "Checking for remote changes…" }
        if store.doltRemoteFreshness.result.hasRemoteChanges {
            return "Remote changes are available. Sync to pull them, push local history, and refresh the readable snapshot."
        }
        if let outcome = project.projectDoltSyncOutcome {
            return "\(outcome.title). \(outcome.detail)"
        }
        return "Pull changes, push Dolt history, then refresh Beadazzle's readable snapshot"
    }

    private var idleAccessibilityLabel: String {
        title == "Sync" ? "Beads Sync" : title
    }

    private var accessibilityLabel: String {
        store.doltRemoteFreshness.result.hasRemoteChanges
            ? "\(idleAccessibilityLabel), remote changes available"
            : idleAccessibilityLabel
    }

    private var remoteStatusSummary: String {
        if store.doltRemoteFreshness.isChecking {
            return "Checking for remote changes…"
        }
        return "Remote: \(store.doltRemoteFreshness.result.summary)"
    }

    private var remoteStatusDetail: String {
        if store.doltRemoteFreshness.isChecking {
            return "Beadazzle is checking the configured Dolt remote for changes."
        }
        return store.doltRemoteFreshness.result.detail
    }

    private func outcomeSystemImage(_ result: ProjectDoltSyncOutcome.Result) -> String {
        switch result {
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private func syncButton(_ command: ProjectDoltSyncCommand) -> some View {
        Button(command.title, systemImage: command.systemImage) {
            perform(command)
        }
        .disabled(!store.canSynchronizeProjectIssues)
    }

    private func perform(_ command: ProjectDoltSyncCommand) {
        Task { @MainActor in
            switch command {
            case .pull:
                _ = await store.pullProjectIssues(
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    completionRefresh: completionRefresh
                )
            case .push:
                _ = await store.pushProjectIssues(
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    completionRefresh: completionRefresh
                )
            }
        }
    }

    private func performSync() {
        Task { @MainActor in
            _ = await store.synchronizeProjectIssues(
                reportsFailureInWorkspace: reportsFailureInWorkspace,
                completionRefresh: completionRefresh
            )
        }
    }
}
