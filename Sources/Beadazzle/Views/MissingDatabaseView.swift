import SwiftUI

struct MissingDatabaseView: View {
    let projectURL: URL
    let isBusy: Bool
    let onSetUp: () -> Void
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
                    Text("No Beads Database Found")
                        .font(.title2.weight(.semibold))

                    Text("Beadazzle can inspect this folder, join an existing tracker, or create a new current Dolt-backed Beads project.")
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
                    HStack(spacing: 10) { setupButton; openProjectButton }
                    VStack(spacing: 10) { setupButton; openProjectButton }
                }

                ProgressView()
                    .controlSize(.small)
                    .opacity(isBusy ? 1 : 0)
                    .accessibilityHidden(!isBusy)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var setupButton: some View {
        Button(action: onSetUp) {
            Label("Set Up Beads", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
    }

    private var openProjectButton: some View {
        Button(action: onOpenProject) {
            Label("Open Different Project", systemImage: "folder")
        }
        .controlSize(.large)
        .disabled(isBusy)
    }
}
