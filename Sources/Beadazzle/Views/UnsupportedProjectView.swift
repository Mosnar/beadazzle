import SwiftUI

struct UnsupportedProjectView: View {
    let projectURL: URL
    let detail: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onOpenProject: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Unsupported Beads Project")
                        .font(.title2.weight(.semibold))

                    Text("Beadazzle supports current Dolt-backed projects in embedded, server, and shared-server modes.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

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
            .frame(maxWidth: 560)
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
