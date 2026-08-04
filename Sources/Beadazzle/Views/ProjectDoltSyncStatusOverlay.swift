import Accessibility
import SwiftUI

/// Keeps project-level remote work visible at the bottom of the sidebar after the toolbar
/// menu closes, then leaves a short-lived result without obscuring the active workspace.
struct ProjectDoltSyncStatusOverlay: View {
    @Environment(BeadStore.self) private var store
    @State private var presentedFailureOutcome: ProjectDoltSyncOutcome?

    private var project: BeadProjectStore { store.project }

    var body: some View {
        Group {
            if let activeAction {
                progressCard(for: activeAction)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else if let visibleOutcome {
                outcomeCard(visibleOutcome)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: presentationID)
        .sheet(item: $presentedFailureOutcome) { outcome in
            ProjectDoltSyncFailureDetailsSheet(outcome: outcome)
        }
        .onChange(of: activeAction) { _, action in
            guard let action else { return }
            AccessibilityNotification.Announcement(progressTitle(for: action)).post()
        }
        .onChange(of: visibleOutcome?.id) { _, _ in
            guard let outcome = visibleOutcome else { return }
            AccessibilityNotification.Announcement(
                "\(outcome.title). \(outcome.detail)"
            ).post()
        }
    }

    private var activeAction: ProjectHealthAction? {
        project.projectHealthAction?.isDoltSync == true ? project.projectHealthAction : nil
    }

    private var visibleOutcome: ProjectDoltSyncOutcome? {
        project.projectDoltSyncOutcome
    }

    private var presentationID: String? {
        if let activeAction {
            return "active-\(activeAction.title)"
        }
        return visibleOutcome.map { "outcome-\($0.id.uuidString)" }
    }

    private func progressCard(for action: ProjectHealthAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)

                Text(progressTitle(for: action))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 4)

                if project.isProjectDoltSyncCancellationRequested {
                    ProgressView()
                        .controlSize(.small)
                        .help("Waiting for the current database operation to finish safely")
                        .accessibilityLabel("Stopping after the current database operation finishes")
                } else {
                    Button("Cancel", systemImage: "xmark") {
                        store.cancelProjectDoltSync()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Stop after the current database operation finishes")
                    .accessibilityHint("The active pull or push will finish safely before Sync stops")
                }
            }

            if let startedAt = project.projectHealthActionStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    progressMetadata(for: action, at: context.date)
                }
            } else {
                progressMetadata(for: action, at: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func progressMetadata(for action: ProjectHealthAction, at date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let command = project.projectDoltSyncPhase?.command {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(progressDetail(for: action, at: date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private func outcomeCard(_ outcome: ProjectDoltSyncOutcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if outcome.hasCommandDetails {
                Button {
                    presentedFailureOutcome = outcome
                } label: {
                    outcomeSummary(outcome, showsDetailsAffordance: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the complete selectable command output")
            } else {
                outcomeSummary(outcome, showsDetailsAffordance: false)
            }

            Spacer(minLength: 0)

            Button("Dismiss", systemImage: "xmark") {
                store.dismissProjectDoltSyncOutcome(id: outcome.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 3, y: 1)
        .help(outcome.detail)
        .accessibilityElement(children: .contain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func outcomeSummary(
        _ outcome: ProjectDoltSyncOutcome,
        showsDetailsAffordance: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcomeSystemImage(outcome.result))
                .foregroundStyle(outcomeColor(outcome.result))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(outcome.title)
                    .font(.callout.weight(.semibold))

                Text(outcome.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                if showsDetailsAffordance {
                    Text("Show Command Output…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }

    private func progressTitle(for action: ProjectHealthAction) -> String {
        if project.isProjectDoltSyncCancellationRequested {
            if let command = project.projectDoltSyncPhase?.command {
                return "Stopping after \(command) finishes"
            }
            return "Stopping safely"
        }
        if let phase = project.projectDoltSyncPhase {
            return phase.title
        }
        return switch action {
        case .synchronizingIssues:
            "Syncing beads with remote"
        case .pullingIssues:
            "Pulling beads from remote"
        case .pushingIssues:
            "Pushing beads to remote"
        default:
            action.title
        }
    }

    private func progressDetail(for action: ProjectHealthAction, at date: Date?) -> String {
        let detail = project.isProjectDoltSyncCancellationRequested
            ? "The current database operation will not be interrupted; later Sync steps will be skipped."
            : project.projectDoltSyncPhase?.detail ?? fallbackDetail(for: action)

        guard let startedAt = project.projectHealthActionStartedAt, let date else { return detail }
        let totalElapsed = elapsedText(since: startedAt, at: date)
        let longRunningGuidance: String
        if project.projectDoltSyncPhase?.isRemoteDatabaseCommand == true,
           date.timeIntervalSince(startedAt) >= 180 {
            longRunningGuidance = " Still running; Beadazzle will stop this command if it reaches 30 minutes."
        } else {
            longRunningGuidance = ""
        }
        guard let phaseStartedAt = project.projectDoltSyncPhaseStartedAt,
              phaseStartedAt.timeIntervalSince(startedAt) >= 0.5 else {
            return "\(detail) • \(totalElapsed) elapsed\(longRunningGuidance)"
        }
        let phaseElapsed = elapsedText(since: phaseStartedAt, at: date)
        return "\(detail) • \(phaseElapsed) this step • \(totalElapsed) total\(longRunningGuidance)"
    }

    private func fallbackDetail(for action: ProjectHealthAction) -> String {
        switch action {
        case .synchronizingIssues:
            "Pulling, pushing, and refreshing the issue list"
        case .pullingIssues:
            "Pulling remote history and refreshing the issue list"
        case .pushingIssues:
            "Publishing local Dolt history"
        default:
            "Working"
        }
    }

    private func elapsedText(since start: Date, at end: Date) -> String {
        let elapsedSeconds = max(0, Int(end.timeIntervalSince(start)))
        if elapsedSeconds < 60 {
            return "\(elapsedSeconds)s"
        }
        return "\(elapsedSeconds / 60)m \(elapsedSeconds % 60)s"
    }

    private func outcomeSystemImage(_ result: ProjectDoltSyncOutcome.Result) -> String {
        switch result {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private func outcomeColor(_ result: ProjectDoltSyncOutcome.Result) -> Color {
        switch result {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
