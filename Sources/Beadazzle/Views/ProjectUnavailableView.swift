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

    private var offersUpgrade: Bool {
        onUpgradeTracker != nil && trackerMigration.isPending
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: offersUpgrade ? "arrow.up.circle" : "exclamationmark.triangle")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(offersUpgrade ? "This Tracker Needs an Upgrade" : "Couldn’t Open Project")
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
        if offersUpgrade {
            upgradeButton
            openProjectButton
        } else {
            retryButton
            openProjectButton
        }
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
}
