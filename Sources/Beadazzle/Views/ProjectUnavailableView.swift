import SwiftUI

struct ProjectUnavailableView: View {
    let projectURL: URL
    let detail: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onOpenProject: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Couldn’t Open Beads Project")
                        .font(.title2.weight(.semibold))

                    Text("Fix the issue below, then check again. Beadazzle will not initialize or modify this folder automatically.")
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
                        retryButton
                        openProjectButton
                    }

                    VStack(spacing: 10) {
                        retryButton
                        openProjectButton
                    }
                }

                if isRetrying {
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
