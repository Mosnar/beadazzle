import Foundation
@testable import Beadazzle

/// Minimal command surface for store tests whose fixtures are readable JSONL snapshots,
/// but are not initialized on disk as real Beads repositories.
struct CurrentDoltTestCommands: BeadsCommanding {
    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}
    func exportReadableSnapshot(projectURL: URL) async throws {}
    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}
    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String?,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}
    func close(projectURL: URL, ids: [String], reason: String?) async throws {}
    func delete(projectURL: URL, ids: [String]) async throws {}
    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}
    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}
    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}
    func addComment(projectURL: URL, issueID: String, text: String) async throws {}
    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] { [] }
    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] { [] }
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}
    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        .testContext(projectURL: projectURL)
    }
}
