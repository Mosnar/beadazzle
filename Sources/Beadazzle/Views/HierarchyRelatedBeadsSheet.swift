import SwiftUI

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

struct ReopenAncestorBeadsStatusRequest: Identifiable, Equatable {
    let issueIDs: [String]
    let title: String?
    let status: String
    let ancestorIssues: [BeadIssue]

    var id: String {
        "\(status)|" + issueIDs.joined(separator: "|") + "|" + ancestorIssues.map(\.id).joined(separator: "|")
    }

    init(issues: [BeadIssue], status: String, ancestorIssues: [BeadIssue]) {
        let sortedIssues = issues.sorted { $0.id < $1.id }
        self.issueIDs = sortedIssues.map(\.id)
        self.title = sortedIssues.count == 1 ? sortedIssues.first?.title : nil
        self.status = status
        self.ancestorIssues = ancestorIssues
    }

    var ancestorIssueIDs: [String] {
        ancestorIssues.map(\.id).sorted()
    }

    var targetDescription: String {
        if let id = issueIDs.first, let title {
            return "\(id): \(title)"
        }
        return "\(issueIDs.count.formatted()) selected beads"
    }
}

struct ReopenAncestorBeadsSaveRequest: Identifiable, Equatable {
    let issueID: String
    let title: String
    let draft: IssueDraft
    let ancestorIssues: [BeadIssue]

    var id: String {
        "\(issueID)|" + ancestorIssues.map(\.id).joined(separator: "|")
    }

    var ancestorIssueIDs: [String] {
        ancestorIssues.map(\.id).sorted()
    }

    var targetDescription: String {
        "\(issueID): \(title)"
    }
}

struct HierarchyRelatedBeadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let confirmTitle: String
    let relatedIssues: [BeadIssue]
    var cancelAction: () -> Void = {}
    let action: () async -> Bool
    @State private var isWorking = false
    @State private var didFinish = false

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

            HierarchyRelatedBeadsList(issues: relatedIssues)

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    confirm()
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
        .onDisappear {
            guard !didFinish else { return }
            didFinish = true
            cancelAction()
        }
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        cancelAction()
        dismiss()
    }

    private func confirm() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            let didComplete = await action()
            isWorking = false
            if didComplete {
                didFinish = true
                dismiss()
            }
        }
    }
}

struct HierarchyRelatedBeadsList: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issues: [BeadIssue]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(issues) { issue in
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

                    if issue.id != issues.last?.id {
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

func uniqueSortedIssueIDs(_ ids: [String]) -> [String] {
    Array(Set(ids)).sorted()
}
