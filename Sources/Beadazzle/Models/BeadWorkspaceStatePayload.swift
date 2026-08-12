import Foundation

/// Versioned, Codable serialization envelope for a project's persisted workspace state.
///
/// This mirrors the pattern used by `BeadSavedViewsPayload`: a `version` field gates decoding so
/// corrupt or newer payloads can be rejected safely. The in-memory `BeadWorkspaceSnapshot` is kept
/// free of serialization concerns; the bookmark is bridged through `BeadBookmarkToken` (the same
/// Codable form used by saved views) because `BeadBookmark` itself is not Codable.
struct BeadWorkspaceStatePayload: Codable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var bookmark: BeadBookmarkToken
    var activeSavedViewID: UUID?
    var sourceSavedViewID: UUID?
    var savedViewOrdering: BeadSavedViewOrdering?
    var listOrdering: BeadListOrdering?
    var selectedIDs: [String]
    var fullPageDetailIssueID: String?
    var searchText: String
    var statusFilters: [String]
    var typeFilters: [String]
    var priorityFilters: [Int]
    var labelFilters: [String]
    var advancedPredicate: BeadFilterGroup?
    var sort: IssueSort
    var sortDirection: SortDirection
    var issueListMode: IssueListMode
    var outlineState: BeadOutlineSelectionState
    var creationDraft: IssueDraft?
    /// Optional keeps version-1 payloads written before recoverable edit drafts
    /// backward compatible without discarding the rest of the workspace state.
    var issueEditDrafts: [String: IssueEditDraftState]?
    var commentDrafts: [String: String]?

    init(snapshot: BeadWorkspaceSnapshot) {
        version = Self.currentVersion
        bookmark = BeadBookmarkToken(snapshot.bookmark)
        activeSavedViewID = snapshot.activeSavedViewID
        sourceSavedViewID = snapshot.sourceSavedViewID
        savedViewOrdering = snapshot.savedViewOrdering
        listOrdering = snapshot.listOrdering
        selectedIDs = snapshot.selectedIDs.sorted()
        fullPageDetailIssueID = snapshot.fullPageDetailIssueID
        searchText = snapshot.searchText
        statusFilters = snapshot.statusFilters.sorted()
        typeFilters = snapshot.typeFilters.sorted()
        priorityFilters = snapshot.priorityFilters.sorted()
        labelFilters = snapshot.labelFilters.sorted()
        advancedPredicate = snapshot.advancedPredicate
        sort = snapshot.sort
        sortDirection = snapshot.sortDirection
        issueListMode = snapshot.issueListMode
        outlineState = snapshot.outlineState
        creationDraft = snapshot.creationDraft
        issueEditDrafts = snapshot.issueEditDrafts.isEmpty ? nil : snapshot.issueEditDrafts
        commentDrafts = snapshot.commentDrafts.isEmpty ? nil : snapshot.commentDrafts
    }

    func snapshot() -> BeadWorkspaceSnapshot {
        BeadWorkspaceSnapshot(
            bookmark: bookmark.bookmark,
            activeSavedViewID: activeSavedViewID,
            sourceSavedViewID: sourceSavedViewID,
            savedViewOrdering: savedViewOrdering,
            listOrdering: listOrdering ?? .sorted(BeadSavedViewSort(
                field: sort,
                direction: sortDirection
            )),
            selectedIDs: Set(selectedIDs),
            fullPageDetailIssueID: fullPageDetailIssueID,
            searchText: searchText,
            statusFilters: Set(statusFilters),
            typeFilters: Set(typeFilters),
            priorityFilters: Set(priorityFilters),
            labelFilters: Set(labelFilters),
            advancedPredicate: advancedPredicate,
            sort: sort,
            sortDirection: sortDirection,
            issueListMode: issueListMode,
            outlineState: outlineState,
            creationDraft: creationDraft,
            issueEditDrafts: issueEditDrafts ?? [:],
            commentDrafts: commentDrafts ?? [:]
        )
    }
}
