import SwiftUI

struct TrackerRecoveryRequest: Identifiable, Equatable {
    let projectURL: URL

    var id: String { projectURL.standardizedFileURL.path }

    static func automatic(
        projectURL: URL?,
        migrationState: BeadsTrackerMigrationState
    ) -> TrackerRecoveryRequest? {
        guard let projectURL,
              case .recoveryAvailable = migrationState else { return nil }
        return TrackerRecoveryRequest(projectURL: projectURL)
    }
}

struct TrackerRecoverySheet: View {
    @Environment(BeadStore.self) private var store
    @Environment(BeadWorkspaceWindowRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    let request: TrackerRecoveryRequest
    @State private var acknowledgesOtherClones = false
    @State private var acknowledgesRemoteAuthority = false

    var body: some View {
        VStack(spacing: 0) {
            TrackerRecoverySheetHeader(state: store.trackerRecovery)
                .padding(24)

            Divider()

            ScrollView {
                TrackerRecoverySheetContent(
                    state: store.trackerRecovery,
                    acknowledgesOtherClones: $acknowledgesOtherClones,
                    acknowledgesRemoteAuthority: $acknowledgesRemoteAuthority
                )
                .padding(24)
            }

            Divider()

            footer
                .padding(16)
        }
        .frame(
            minWidth: 680,
            idealWidth: 680,
            maxWidth: 680,
            minHeight: 520,
            idealHeight: 620,
            maxHeight: 760
        )
        .interactiveDismissDisabled(store.trackerRecovery.isMutatingTracker)
        .task(id: request.id) {
            guard request.projectURL.standardizedFileURL == store.projectURL?.standardizedFileURL,
                  store.trackerRecovery == .idle else { return }
            store.prepareTrackerRecovery(
                competingWindowBlocker: registry.trackerRecoveryCompetingWindowBlocker(for: store)
            )
        }
        .onDisappear {
            if case .diagnosing = store.trackerRecovery {
                store.cancelTrackerRecovery()
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Link("Official Recovery Guide", destination: BeadsTrackerRecoveryGuide.url)
            Spacer()

            switch store.trackerRecovery {
            case .idle, .review:
                Button("Cancel", role: .cancel) {
                    store.dismissTrackerRecoveryResult()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if case .review(let assessment) = store.trackerRecovery,
                   assessment.canRecover {
                    Button("Back Up and Recover", role: .destructive) {
                        store.startTrackerRecovery(
                            acknowledgesOtherClones: acknowledgesOtherClones,
                            acknowledgesRemoteAuthority: acknowledgesRemoteAuthority,
                            competingWindowBlocker: registry.trackerRecoveryCompetingWindowBlocker(for: store)
                        )
                    }
                    .disabled(!acknowledgesOtherClones || !acknowledgesRemoteAuthority)
                }

            case .diagnosing:
                Button("Cancel", role: .cancel) {
                    store.cancelTrackerRecovery()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

            case .running(let progress):
                Button(
                    progress.phase.finishesCurrentStepBeforeStopping
                        ? "Stop After Current Step"
                        : "Stop Recovery",
                    role: .cancel
                ) {
                    store.cancelTrackerRecovery()
                }
                .help(
                    progress.phase.finishesCurrentStepBeforeStopping
                        ? "The active Dolt repair statement will finish before recovery stops."
                        : "Stop recovery before the next step."
                )

            case .succeeded:
                Button("Done") {
                    store.dismissTrackerRecoveryResult()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)

            case .failed:
                Button("Close", role: .cancel) {
                    store.dismissTrackerRecoveryResult()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Review Again") {
                    store.dismissTrackerRecoveryResult()
                    acknowledgesOtherClones = false
                    acknowledgesRemoteAuthority = false
                    store.prepareTrackerRecovery(
                        competingWindowBlocker: registry.trackerRecoveryCompetingWindowBlocker(for: store)
                    )
                }
            }
        }
    }
}

private struct TrackerRecoverySheetHeader: View {
    let state: BeadsTrackerRecoveryState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text("Beadazzle can help repair a known issue caused by Beads 1.2.0/1.2.1")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var title: String {
        switch state {
        case .idle, .diagnosing, .review: "Repair a Beads Tracker Issue"
        case .running(let progress): progress.phase.title
        case .succeeded: "Tracker Recovery Completed"
        case .failed: "Tracker Recovery Needs Attention"
        }
    }

    private var systemImage: String {
        switch state {
        case .succeeded: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .diagnosing, .review, .running: "cross.case.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .succeeded: .green
        case .failed: .red
        case .idle, .diagnosing, .review, .running: .orange
        }
    }
}

private struct TrackerRecoverySheetContent: View {
    let state: BeadsTrackerRecoveryState
    @Binding var acknowledgesOtherClones: Bool
    @Binding var acknowledgesRemoteAuthority: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch state {
            case .idle, .diagnosing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the exact schema incident, effective tracker, tools, app activity, backup space, and destination…")
                }

            case .review(let assessment):
                assessmentContent(assessment)

            case .running(let progress):
                Label(progress.phase.title, systemImage: "gearshape.2")
                    .font(.headline)
                ProgressView()
                Text("Beadazzle is using bounded subprocesses and will keep the tracker read-only until post-recovery validation succeeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                recoveryLog(progress.log)

            case .succeeded(let result):
                Label("The local tracker passed every post-recovery check.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                backupLocation(result.backupURL)
                Label(BeadsTrackerRecoveryResult.publicationGuidance, systemImage: "network")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                recoveryLog(result.log)

            case .failed(let failure):
                Label(failure.message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let backupURL = failure.backupURL {
                    backupLocation(backupURL)
                }
                Text("Do not publish or pull this tracker until recovery validation succeeds. The official guide can be used for manual follow-up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                recoveryLog(failure.log)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assessmentContent(_ assessment: BeadsTrackerRecoveryAssessment) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Beadazzle did not cause this tracker issue. Beads 1.2.0/1.2.1 accidentally upgraded the database to schema v65. Beadazzle detected the exact v65/v53 mismatch documented by Beads and can help apply its backup-first repair using the healthy Beads 1.2.2 release.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(assessment.checks) { check in
                    TrackerRecoveryCheckRow(check: check)
                }
            }

            if let blockingMessage = assessment.blockingMessage {
                Label(blockingMessage, systemImage: "hand.raised.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if assessment.canRecover {
                Divider()
                Label("Other machines and clones", systemImage: "desktopcomputer")
                    .font(.headline)
                Text("Upgrade every machine and clone to bd 1.2.2 first. A leftover accidental binary can silently reapply schema v65.")
                    .foregroundStyle(.secondary)
                Toggle(
                    "Other writers are stopped and every participating clone uses bd 1.2.2",
                    isOn: $acknowledgesOtherClones
                )

                Label("Remote authority and publication", systemImage: "network")
                    .font(.headline)
                Text("Recovery is local only. Do not pull first. Decide which recovered clone is authoritative, then publish separately if the team uses a Dolt remote.")
                    .foregroundStyle(.secondary)
                Toggle(
                    "I understand recovery will not pull or push, and publication is a separate decision",
                    isOn: $acknowledgesRemoteAuthority
                )
            }
        }
    }

    private func backupLocation(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recovery backup")
                .font(.headline)
            Text(url.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }

    private func recoveryLog(_ entries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result log")
                .font(.headline)
            Text(entries.isEmpty ? "No recovery steps completed." : entries.joined(separator: "\n"))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TrackerRecoveryCheckRow: View {
    let check: BeadsTrackerRecoveryCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status == .passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(check.status == .passed ? .green : .red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.headline)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(check.status.accessibilityDescription): \(check.title)")
        .accessibilityValue(check.detail)
    }
}
