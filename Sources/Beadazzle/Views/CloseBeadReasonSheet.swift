import SwiftUI

struct CloseBeadRequest: Identifiable, Equatable {
    let issueIDs: [String]
    let title: String?

    var id: String {
        issueIDs.joined(separator: "|")
    }

    init(issue: BeadIssue) {
        self.issueIDs = [issue.id]
        self.title = issue.title
    }

    init(issues: [BeadIssue]) {
        let sortedIssues = issues.sorted { $0.id < $1.id }
        self.issueIDs = sortedIssues.map(\.id)
        self.title = sortedIssues.count == 1 ? sortedIssues.first?.title : nil
    }

    var dialogTitle: String {
        issueIDs.count == 1 ? "Close Bead" : "Close \(issueIDs.count.formatted()) Beads"
    }

    var targetDescription: String {
        if let id = issueIDs.first, let title {
            return "\(id): \(title)"
        }
        return "\(issueIDs.count.formatted()) selected beads"
    }

    var closeButtonTitle: String {
        issueIDs.count == 1 ? "Close" : "Close Selected"
    }
}

struct CloseBeadReasonSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss
    let request: CloseBeadRequest
    @State private var reason = ""
    @State private var isClosing = false
    @FocusState private var reasonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.dialogTitle)
                    .font(.title3.weight(.semibold))
                Text(request.targetDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Reason", text: $reason, prompt: Text("Optional"))
                    .focused($reasonFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(close)
                    .accessibilityHint("Leave blank to close without a reason.")
                    .disabled(isClosing)

                Text("Leave blank to close without a reason.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isClosing)

                if isClosing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    close()
                } label: {
                    Label(request.closeButtonTitle, systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isClosing)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .defaultFocus($reasonFocused, true)
        .interactiveDismissDisabled(isClosing)
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        Task { @MainActor in
            let didClose = await store.close(issueIDs: request.issueIDs, reason: reason.nilIfBlank)
            isClosing = false
            if didClose {
                dismiss()
            }
        }
    }
}
