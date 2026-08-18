import SwiftUI

struct ProjectUnavailableView: View {
    let projectURL: URL
    let detail: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onOpenProject: () -> Void
    /// Present only when the project is blocked by a pending `bd` schema upgrade, which
    /// Beadazzle can run itself. `nil` keeps the generic "fix it yourself" guidance.
    var trackerMigration: BeadsTrackerMigrationState = .notNeeded
    var onUpgradeTracker: (() -> Void)?
    var onReviewRecovery: (() -> Void)?

    private var offersUpgrade: Bool {
        onUpgradeTracker != nil && trackerMigration.usesUpwardMigration
    }

    private var offersRecovery: Bool {
        onReviewRecovery != nil && trackerMigration.canReviewRecovery
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: schemaSystemImage)
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))

                    Text(guidance)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Text(projectURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(projectURL.path)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        primaryButtons
                    }

                    VStack(spacing: 10) {
                        primaryButtons
                    }
                }

                if isRetrying || trackerMigration.isMigrating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(32)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var guidance: String {
        if offersRecovery {
            return BeadsSchemaSkewResolution.guidedRecovery.guidance
        }
        if case .recoveryBlocked(_, let guidance) = trackerMigration {
            return guidance
        }
        guard offersUpgrade else {
            return "Fix the issue below, then check again. Beadazzle will not initialize or modify this folder automatically."
        }
        if trackerMigration.isMigrating {
            return "Upgrading this tracker for the installed version of bd. This can take a few minutes on a large project."
        }
        if case .awaitingConfirmation(_, let reason) = trackerMigration {
            return reason.explanation
        }
        return "A newer version of bd needs to upgrade this tracker's database once before Beadazzle can read it."
    }

    @ViewBuilder
    private var primaryButtons: some View {
        if offersRecovery {
            recoveryButton
            openProjectButton
        } else if trackerMigration.isRecoveryBlocked {
            Link(destination: BeadsTrackerRecoveryGuide.url) {
                Label("Open Recovery Guide", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            openProjectButton
        } else if offersUpgrade {
            upgradeButton
            openProjectButton
        } else {
            retryButton
            openProjectButton
        }
    }

    private var recoveryButton: some View {
        Button {
            onReviewRecovery?()
        } label: {
            Label("Review Recovery", systemImage: "cross.case")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isRetrying)
    }

    @ViewBuilder
    private var upgradeButton: some View {
        Button {
            onUpgradeTracker?()
        } label: {
            Label(
                trackerMigration.isMigrating ? "Upgrading Tracker" : "Upgrade Tracker",
                systemImage: "arrow.up.circle"
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isRetrying || trackerMigration.isMigrating)
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Label(isRetrying ? "Checking Again" : "Check Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isRetrying)
    }

    private var openProjectButton: some View {
        Button(action: onOpenProject) {
            Label("Open Different Project", systemImage: "folder")
        }
        .controlSize(.large)
        .disabled(isRetrying)
    }

    private var title: String {
        trackerMigration.schemaResolution?.title ?? "Couldn’t Open Project"
    }

    private var schemaSystemImage: String {
        trackerMigration.schemaResolution?.systemImage ?? "exclamationmark.triangle"
    }
}
