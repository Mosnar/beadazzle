import SwiftUI

/// Explains a pending one-time `bd` schema upgrade and offers to run it.
///
/// The issue list stays visible behind this: the JSONL snapshot still reads, so the
/// project is browsable with stale data while the upgrade is pending. Writes are
/// refused until it completes, which this banner says plainly rather than letting each
/// edit fail on its own.
struct TrackerMigrationBanner: View {
    let state: BeadsTrackerMigrationState
    let upgrade: () -> Void
    let confirmUpgrade: () -> Void
    let retry: () -> Void
    let reviewRecovery: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .migrating:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .notNeeded, .awaitingConfirmation, .ready, .failed,
             .recoveryAvailable, .recoveryBlocked:
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .ready:
            Button("Upgrade Tracker", action: upgrade)
                .buttonStyle(.borderedProminent)
        case .awaitingConfirmation:
            Button("Upgrade Tracker", action: confirmUpgrade)
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Try Again", action: retry)
        case .recoveryAvailable:
            Button("Review Recovery…", action: reviewRecovery)
                .buttonStyle(.borderedProminent)
        case .recoveryBlocked:
            Link("Open Recovery Guide", destination: BeadsTrackerRecoveryGuide.url)
        case .migrating, .notNeeded:
            EmptyView()
        }
    }

    private var tint: Color {
        state.isFailure ? .red : .orange
    }

    private var title: String {
        switch state {
        case .migrating:
            return "Upgrading tracker data…"
        case .failed:
            return "Tracker upgrade failed"
        case .recoveryAvailable(let skew), .recoveryBlocked(let skew, _),
             .awaitingConfirmation(let skew, _), .ready(let skew):
            return skew.resolution.healthSummary
        case .notNeeded:
            return ""
        }
    }

    private var detail: String {
        switch state {
        case .ready(let skew):
            return [
                skew.versionSummary,
                "Beadazzle is showing data from the last export until the upgrade finishes."
            ]
                .compactMap { $0 }
                .joined(separator: " ")
        case .awaitingConfirmation(let skew, let reason):
            return [skew.versionSummary, reason.explanation]
                .compactMap { $0 }
                .joined(separator: " ")
        case .migrating:
            return "This can take a few minutes on a large project. Editing is paused until it finishes."
        case .failed(let message, let requiresDesignatedMigrator):
            guard requiresDesignatedMigrator else { return message }
            return """
            \(message) bd will not upgrade a remote-backed database on its own. \
            Confirm you are the designated migrator, then push the upgraded schema.
            """
        case .recoveryAvailable(let skew):
            return [
                skew.versionSummary,
                "\(skew.resolution.guidance) Editing remains paused."
            ]
                .compactMap { $0 }
                .joined(separator: " ")
        case .recoveryBlocked(let skew, let guidance):
            return [skew.versionSummary, guidance]
                .compactMap { $0 }
                .joined(separator: " ")
        case .notNeeded:
            return ""
        }
    }

    private var systemImage: String {
        state.schemaResolution?.systemImage ?? "arrow.up.circle.fill"
    }
}

extension BeadsTrackerMigrationState {
    fileprivate var isFailure: Bool {
        switch self {
        case .failed, .recoveryBlocked: true
        case .notNeeded, .awaitingConfirmation, .ready, .migrating, .recoveryAvailable: false
        }
    }
}
