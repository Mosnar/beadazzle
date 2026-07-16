import AppKit
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

            if hasTechnicalDetails {
                technicalDetails
            }

            HStack(spacing: 10) {
                if hasTechnicalDetails {
                    Button("Copy", systemImage: "doc.on.doc", action: copyDetails)
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

    private var trimmedCommand: String? {
        failure.command?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private var trimmedOutput: String? {
        failure.output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private var hasTechnicalDetails: Bool {
        trimmedCommand != nil || trimmedOutput != nil
    }

    /// Short output renders inline; long output gets a fixed-height scroll region so a
    /// verbose `bd` failure can't grow the sheet past usefulness.
    private var outputNeedsScrolling: Bool {
        guard let trimmedOutput else { return false }
        return trimmedOutput.count > 600
            || trimmedOutput.components(separatedBy: "\n").count > 8
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let trimmedCommand {
                Text(trimmedCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityLabel("Command: \(trimmedCommand)")
            }

            if let trimmedOutput {
                if trimmedCommand != nil {
                    Divider()
                }
                if outputNeedsScrolling {
                    ScrollView {
                        outputText(trimmedOutput)
                            .padding(10)
                    }
                    .frame(height: 150)
                } else {
                    outputText(trimmedOutput)
                        .padding(10)
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private func outputText(_ output: String) -> some View {
        Text(output)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Output: \(output)")
    }

    private func copyDetails() {
        let details = [trimmedCommand, trimmedOutput].compactMap(\.self).joined(separator: "\n\n")
        guard !details.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(details, forType: .string)
    }
}

extension View {
    func mutationErrorDialog(store: BeadStore) -> some View {
        modifier(MutationErrorDialogModifier(store: store))
    }
}
