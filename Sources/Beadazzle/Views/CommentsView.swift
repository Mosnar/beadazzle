import SwiftUI

struct CommentsView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    private var detail: BeadDetailStore { store.detail }
    let issue: BeadIssue
    @State private var draftText = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        let comments = store.comments(for: issue.id)
        let isLoadingComments = store.isLoadingComments(for: issue.id)
        let commentLoadError = store.commentLoadError(for: issue.id)
        let issueReferenceLookup = project.issueReferenceLookup

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.headline)
                if isLoadingComments {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(comments.count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.loadCommentsForSelection(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh comments")
                .disabled(isLoadingComments)
            }

            if isLoadingComments && comments.isEmpty {
                Text("Loading comments...")
                    .foregroundStyle(.secondary)
            } else if let commentLoadError {
                Label(commentLoadError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if comments.isEmpty {
                Text("No comments.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment, issueReferenceLookup: issueReferenceLookup)
                            .equatable()
                        if comment.id != comments.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Divider()
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draftText)
                    .focused($composerFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 110)
                    .padding(6)
                    .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    }

                HStack {
                    Spacer()
                    Button {
                        submitComment()
                    } label: {
                        Label("Comment", systemImage: "paperplane")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(normalizedDraft.isEmpty || detail.isAddingComment)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .task(id: CommentLoadTaskID(issueID: issue.id, commentCount: issue.commentCount)) {
            store.loadCommentsForSelection()
        }
        .onChange(of: issue.id) {
            draftText = ""
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let issueID = BeadIssueURL.issueID(from: url),
                  store.issue(with: issueID) != nil else {
                // Not a resolvable bead link — let the system handle it so any
                // ordinary URL in a comment still opens.
                return .systemAction
            }
            store.openIssueFromDetail(issueID: issueID)
            return .handled
        })
    }

    private var normalizedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitComment() {
        let text = normalizedDraft
        guard !text.isEmpty else { return }
        store.addComment(issueID: issue.id, text: text)
        draftText = ""
        composerFocused = false
    }
}

private struct CommentLoadTaskID: Hashable {
    let issueID: String
    let commentCount: Int
}

// Equatable on (comment, lookup revision) so `.equatable()` skips body — and
// with it the reference-matching pass — unless the comment text or the
// project's set of issue IDs actually changed.
private struct CommentRow: View, Equatable {
    let comment: BeadComment
    let issueReferenceLookup: IssueReferenceLookup

    static func == (lhs: CommentRow, rhs: CommentRow) -> Bool {
        lhs.comment == rhs.comment
            && lhs.issueReferenceLookup.revision == rhs.issueReferenceLookup.revision
    }

    private var attributedText: AttributedString {
        IssueReferenceAttributedStringBuilder.make(
            text: comment.text,
            lookup: issueReferenceLookup
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(comment.author?.nilIfBlank ?? "Unknown")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(BeadFormatters.displayDate(comment.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(attributedText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}
