import SwiftUI

/// The single standardized error surface for mutation/command failures. Presented as a
/// sheet rather than an `.alert` so the failing `bd` command and its output can be shown
/// in selectable, monospaced, copyable text — the whole point of surfacing them to
/// technical users. Driven by `sheet(item:)` keyed on the failure's identity, so queued
/// failures present one after another deterministically.
///
/// Attach once near the app's content root with `.mutationErrorDialog(store:)`; failures
/// enqueued from anywhere in `BeadStore` present here, one at a time.
private struct MutationErrorDialogModifier: ViewModifier {
    @Bindable var store: BeadStore

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { store.currentFailure },
            // Dismissal is driven entirely by the dialog's buttons (Escape included, via
            // onExitCommand), so the queue is popped exactly once per resolution. The item's
            // identity change after a pop drives dismissal and re-presentation of the next
            // queued failure.
            set: { _ in }
        )) { failure in
            MutationErrorDialogView(failure: failure, store: store)
        }
    }
}

private struct MutationErrorDialogView: View {
    let failure: BeadMutationFailure
    let store: BeadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title)
                        .font(.headline)
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !technicalDetails.isEmpty {
                BeadCommandFailureDetailsView(details: technicalDetails)
            }

            HStack(spacing: 10) {
                if !technicalDetails.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        technicalDetails.copyToPasteboard()
                    }
                        .help("Copy the command and its output")
                }

                Spacer()

                if failure.isRetryable {
                    Button("Cancel", role: .cancel) { store.dismissCurrentFailure() }
                    Button("Try Again") { store.retryCurrentFailure() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("OK") { store.dismissCurrentFailure() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { store.dismissCurrentFailure() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(failure.accessibilityAnnouncement)
    }

    private var technicalDetails: BeadCommandFailureDetails {
        BeadCommandFailureDetails(command: failure.command, output: failure.output)
    }
}

extension View {
    func mutationErrorDialog(store: BeadStore) -> some View {
        modifier(MutationErrorDialogModifier(store: store))
    }
}
