import SwiftUI

/// Compact access to Dolt synchronization. The primary action pulls and pushes the
/// authoritative database, then refreshes Beadazzle's readable snapshot; the menu keeps
/// explicit directional commands available for recovery and advanced workflows.
struct ProjectDoltSyncMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore
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
        Menu {
            syncButton(.pull)
            syncButton(.push)

            Divider()

            Button("Check for Remote Changes", systemImage: "arrow.clockwise") {
                store.checkProjectDoltRemoteFreshness(.manual)
            }
            .disabled(
                store.doltRemoteFreshness.isChecking
                    || !store.doltRemoteFreshness.result.canCheckAgain
            )
            .help(store.doltRemoteFreshness.result.detail)

            Text(remoteStatusSummary)
        } label: {
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
        } primaryAction: {
            performSync()
        }
        .disabled(isExternallyDisabled || !store.canSynchronizeProjectIssues)
        .help(syncHelp)
        .accessibilityLabel(activeSyncAction?.title ?? accessibilityLabel)
        .accessibilityHint(activeSyncAction == nil ? syncHelp : "Please wait")
    }

    private var activeSyncAction: ProjectHealthAction? {
        switch store.projectHealthAction {
        case .synchronizingIssues, .pullingIssues, .pushingIssues:
            store.projectHealthAction
        default:
            nil
        }
    }

    private var syncHelp: String {
        if store.isLoadingProjectDoltRemotes {
            return "Checking this project for a Dolt remote"
        }
        if let activeSyncAction { return activeSyncAction.title }
        if store.doltRemoteFreshness.isChecking { return "Checking the Dolt remote for changes" }
        if store.doltRemoteFreshness.result.hasRemoteChanges {
            return "Remote changes are available. Sync to pull them, push local history, and refresh the readable snapshot."
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
            return "Checking remote…"
        }
        return "Remote: \(store.doltRemoteFreshness.result.summary)"
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
