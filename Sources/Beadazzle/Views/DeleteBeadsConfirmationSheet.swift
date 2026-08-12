import SwiftUI

struct DeleteBeadsConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: DeleteBeadsRequest
    let delete: ([String]) async -> Bool
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.dialogTitle)
                    .font(.title3.weight(.semibold))
                Text(request.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            deletePreviewSection(title: "Selected", issues: request.selectedIssues)

            if !request.childIssues.isEmpty {
                deletePreviewSection(title: "Descendants", issues: request.childIssues)
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Deleting beads")
                }

                if request.childIssues.isEmpty {
                    deleteButton(request.actionTitle, issueIDs: request.issueIDs, isPrimary: true)
                } else {
                    deleteButton(
                        request.deleteSelectedActionTitle,
                        issueIDs: request.issueIDs,
                        isPrimary: false
                    )
                    deleteButton(
                        request.deleteAllActionTitle,
                        issueIDs: request.allIssueIDs,
                        isPrimary: true
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .interactiveDismissDisabled(isWorking)
    }

    private func deletePreviewSection(title: String, issues: [BeadIssue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(issues.count.formatted()))")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HierarchyRelatedBeadsList(issues: issues)
        }
    }

    @ViewBuilder
    private func deleteButton(_ title: String, issueIDs: [String], isPrimary: Bool) -> some View {
        if isPrimary {
            Button(title, role: .destructive) {
                performDelete(issueIDs: issueIDs)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isWorking)
        } else {
            Button(title, role: .destructive) {
                performDelete(issueIDs: issueIDs)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
        }
    }

    private func performDelete(issueIDs: [String]) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            _ = await delete(issueIDs)
            isWorking = false
            // The shared mutation-failure sheet lives at the workspace root. Close this
            // confirmation surface after the attempt so any queued error can present.
            dismiss()
        }
    }
}
