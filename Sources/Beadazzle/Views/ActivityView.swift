import SwiftUI

/// The issue detail's Activity section: history events and comments merged into one
/// oldest-first feed (compact event rows, full comment rows), with the composer below.
struct ActivityView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue

    var body: some View {
        let isLoadingComments = store.isLoadingComments(for: issue.id)
        let isLoadingHistory = store.isLoadingActivity(for: issue.id)
        let commentLoadError = store.commentLoadError(for: issue.id)
        let activityLoadError = store.activityLoadError(for: issue.id)
        let issueReferenceLookup = store.project.issueReferenceLookup
        let items = store.activityItems(for: issue.id)
        let isRefreshing = store.activityIssueID != issue.id
            || isLoadingComments
            || isLoadingHistory
            || store.snapshotFreshness.state == .refreshing

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(.headline)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(items.count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.refreshActivityForSelection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh activity")
                .disabled(isRefreshing)
            }

            if let commentLoadError {
                Label(commentLoadError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let activityLoadError {
                Label(activityLoadError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isRefreshing && items.isEmpty {
                Text("Loading activity...")
                    .foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("No activity.")
                    .foregroundStyle(.secondary)
            } else {
                ActivityFeed(items: items, issueReferenceLookup: issueReferenceLookup)
                    .equatable()
            }

            Divider()
                .padding(.top, 2)

            // Own subview (with its own `@State` draft) so typing a comment only
            // re-renders the composer, not the merged feed above it.
            ActivityComposer(issueID: issue.id)
                .id(issue.id)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .task(id: ActivityLoadTaskID(issueID: issue.id, commentCount: issue.commentCount)) {
            store.loadCommentsForSelection()
            store.loadActivityForSelection()
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
}

private struct ActivityComposer: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var detail: BeadDetailStore { store.detail }
    let issueID: String
    @State private var draftText = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
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

    private var normalizedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitComment() {
        let text = normalizedDraft
        guard !text.isEmpty else { return }
        store.addComment(issueID: issueID, text: text)
        draftText = ""
        composerFocused = false
    }
}

private struct ActivityLoadTaskID: Hashable {
    let issueID: String
    let commentCount: Int
}

/// Own view boundary for relative grouping so unrelated detail-store updates do
/// not rebuild the presentation sequence. The reference date advances only when
/// the system calendar day or time zone changes; neither path reloads activity.
private struct ActivityFeed: View, Equatable {
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @State private var referenceDate = Date.now

    let items: [IssueActivityItem]
    let issueReferenceLookup: IssueReferenceLookup

    static func == (lhs: ActivityFeed, rhs: ActivityFeed) -> Bool {
        lhs.items == rhs.items
            && lhs.issueReferenceLookup.revision == rhs.issueReferenceLookup.revision
    }

    var body: some View {
        let elements = IssueActivityDateGrouping.elements(
            for: items,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )

        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(elements) { element in
                ActivityFeedElementRow(
                    element: element,
                    issueReferenceLookup: issueReferenceLookup
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            referenceDate = .now
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            referenceDate = .now
        }
    }
}

/// A unary row keeps the lazy container's per-element structure constant while
/// selecting a time boundary or an activity item.
private struct ActivityFeedElementRow: View {
    let element: IssueActivityFeedElement
    let issueReferenceLookup: IssueReferenceLookup

    var body: some View {
        Group {
            switch element {
            case .boundary(let boundary):
                ActivityDateBoundaryRow(boundary: boundary)
            case .item(let item):
                ActivityItemRow(item: item, issueReferenceLookup: issueReferenceLookup)
            }
        }
    }
}

private struct ActivityDateBoundaryRow: View {
    let boundary: IssueActivityDateBoundary

    private var accent: Color {
        boundary.isToday ? .accentColor : .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            rule
            Text(boundary.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(accent.opacity(boundary.isToday ? 0.14 : 0.08), in: Capsule())
                .accessibilityAddTraits(.isHeader)
            rule
        }
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var rule: some View {
        Rectangle()
            .fill(accent.opacity(boundary.isToday ? 0.75 : 0.25))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A unary row keeps the lazy container's per-element structure constant while the
/// row itself selects the appropriate compact event or full comment presentation.
private struct ActivityItemRow: View {
    let item: IssueActivityItem
    let issueReferenceLookup: IssueReferenceLookup

    var body: some View {
        Group {
            switch item {
            case .event(let event):
                ActivityEventRow(event: event)
            case .comment(let comment):
                CommentRow(comment: comment, issueReferenceLookup: issueReferenceLookup)
                    .equatable()
            }
        }
    }
}

/// A compact one-line history entry ("Beadazzle closed this bead"), with the
/// close/state-change reason underneath when one was recorded.
private struct ActivityEventRow: View {
    let event: IssueActivityEventPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: event.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                messageText
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let reference = event.reference {
                    ActivityReferenceLink(reference: reference)
                }
                Text(BeadFormatters.displayDate(event.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            if let reason = event.reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var messageText: Text {
        if let actor = event.actor?.nilIfBlank {
            Text(actor).foregroundStyle(.primary) + Text(" \(event.message)")
        } else {
            Text(event.standaloneMessage)
        }
    }
}

/// An inline bead reference in an event row ("set the parent to <bd-x Title>"):
/// clickable, with the same delayed hover preview beads get everywhere else
/// (`HoverPersistentPopover` + `BeadDetailPreview`, as in `SidebarBeadLink`).
/// A reference to a deleted bead degrades to plain text.
private struct ActivityReferenceLink: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let reference: IssueActivityReference

    var body: some View {
        if let issue = store.issue(with: reference.issueID) {
            HoverPersistentPopover(fillsAvailableWidth: false) {
                store.openIssueFromDetail(issueID: issue.id)
            } label: { isHovered in
                referenceText
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .background(
                        isHovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            } preview: {
                BeadDetailPreview(issue: issue)
            }
            .help("\(issue.id) \(issue.title)")
            .accessibilityLabel("\(issue.title), \(issue.id)")
            .accessibilityHint("Opens the bead")
        } else {
            referenceText
                .foregroundStyle(.secondary)
        }
    }

    private var referenceText: some View {
        Text(reference.displayText)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
    }
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
