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

struct CloseChildBeadsStatusRequest: Identifiable, Equatable {
    let issueIDs: [String]
    let title: String?
    let status: String
    let childIssues: [BeadIssue]

    var id: String {
        "\(status)|" + issueIDs.joined(separator: "|") + "|" + childIssues.map(\.id).joined(separator: "|")
    }

    init(issues: [BeadIssue], status: String, childIssues: [BeadIssue]) {
        let sortedIssues = issues.sorted { $0.id < $1.id }
        self.issueIDs = sortedIssues.map(\.id)
        self.title = sortedIssues.count == 1 ? sortedIssues.first?.title : nil
        self.status = status
        self.childIssues = childIssues
    }

    var allIssueIDs: [String] {
        uniqueSortedIssueIDs(issueIDs + childIssues.map(\.id))
    }

    var targetDescription: String {
        if let id = issueIDs.first, let title {
            return "\(id): \(title)"
        }
        return "\(issueIDs.count.formatted()) selected beads"
    }
}

struct CloseChildBeadsSaveRequest: Identifiable, Equatable {
    let issueID: String
    let title: String
    let draft: IssueDraft
    let childIssues: [BeadIssue]

    var id: String {
        "\(issueID)|" + childIssues.map(\.id).joined(separator: "|")
    }

    var childIssueIDs: [String] {
        childIssues.map(\.id).sorted()
    }

    var targetDescription: String {
        "\(issueID): \(title)"
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
        let openChildIssues = store.openChildIssues(forClosing: request.issueIDs)

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

            if !openChildIssues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Close child beads too?")
                        .font(.headline)
                    Text(childCloseMessage(for: openChildIssues.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    OpenChildBeadsList(childIssues: openChildIssues)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Reason", text: $reason, prompt: Text("Optional"))
                    .focused($reasonFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        close(includingChildren: !openChildIssues.isEmpty)
                    }
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

                if !openChildIssues.isEmpty {
                    Button(closeOnlyButtonTitle) {
                        close(includingChildren: false)
                    }
                    .disabled(isClosing)
                }

                Button {
                    close(includingChildren: !openChildIssues.isEmpty)
                } label: {
                    Label(closeButtonTitle(openChildCount: openChildIssues.count), systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isClosing)
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .defaultFocus($reasonFocused, true)
        .interactiveDismissDisabled(isClosing)
    }

    private func close(includingChildren: Bool) {
        guard !isClosing else { return }
        isClosing = true
        let childIssueIDs = includingChildren ? store.openChildIssues(forClosing: request.issueIDs).map(\.id) : []
        let issueIDs = uniqueSortedIssueIDs(request.issueIDs + childIssueIDs)
        Task { @MainActor in
            let didClose = await store.close(issueIDs: issueIDs, reason: reason.nilIfBlank)
            isClosing = false
            if didClose {
                dismiss()
            }
        }
    }

    private func childCloseMessage(for count: Int) -> String {
        let childText = count == 1 ? "child bead" : "child beads"
        return "\(count.formatted()) open \(childText) will be closed as well."
    }

    private func closeButtonTitle(openChildCount: Int) -> String {
        openChildCount > 0 ? "Close All" : request.closeButtonTitle
    }

    private var closeOnlyButtonTitle: String {
        request.issueIDs.count == 1 ? "Close Bead Only" : "Close Selected Only"
    }
}

struct CloseChildBeadsConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let confirmTitle: String
    let childIssues: [BeadIssue]
    var secondaryTitle: String? = nil
    var secondaryAction: (() async -> Bool)? = nil
    let action: () async -> Bool
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OpenChildBeadsList(childIssues: childIssues)

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle) {
                        confirm(performing: secondaryAction)
                    }
                    .disabled(isWorking)
                }

                Button {
                    confirm(performing: action)
                } label: {
                    Label(confirmTitle, systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .interactiveDismissDisabled(isWorking)
    }

    private func confirm(performing action: @escaping () async -> Bool) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            let didComplete = await action()
            isWorking = false
            if didComplete {
                dismiss()
            }
        }
    }
}

private struct OpenChildBeadsList: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let childIssues: [BeadIssue]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(childIssues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: store.statusSymbol(for: issue.status))
                            .foregroundStyle(store.statusColor(for: issue.status))
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(issue.title)
                                .font(.callout)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Text(issue.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(issue.id), \(issue.title), status: \(issue.status)")

                    if issue.id != childIssues.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxHeight: 180)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private func uniqueSortedIssueIDs(_ ids: [String]) -> [String] {
    Array(Set(ids)).sorted()
}
