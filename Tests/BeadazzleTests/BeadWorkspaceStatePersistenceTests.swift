import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadWorkspaceStatePersistenceTests: XCTestCase {
    func testPayloadRoundTripPreservesEveryField() throws {
        let snapshot = makeSnapshot()

        let payload = BeadWorkspaceStatePayload(snapshot: snapshot)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(BeadWorkspaceStatePayload.self, from: data)

        XCTAssertEqual(decoded.version, BeadWorkspaceStatePayload.currentVersion)
        XCTAssertEqual(decoded.snapshot(), snapshot)
    }

    func testPayloadBridgesInProgressBookmarkThroughStableToken() throws {
        var snapshot = makeSnapshot()
        snapshot.bookmark = .inProgress

        let data = try JSONEncoder().encode(BeadWorkspaceStatePayload(snapshot: snapshot))
        // The wire form must use the saved-view token spelling so persisted state stays compatible.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("in_progress"))

        let decoded = try JSONDecoder().decode(BeadWorkspaceStatePayload.self, from: data)
        XCTAssertEqual(decoded.snapshot().bookmark, .inProgress)
    }

    func testRepositorySaveThenLoadReturnsEquivalentSnapshot() {
        let defaults = makeUserDefaults()
        let repository = BeadWorkspaceStateRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/BeadazzleTests/ProjectA")
        let snapshot = makeSnapshot()

        XCTAssertNil(repository.load(projectURL: projectURL))
        XCTAssertTrue(repository.save(BeadWorkspaceStatePayload(snapshot: snapshot), projectURL: projectURL))

        let loaded = repository.load(projectURL: projectURL)
        XCTAssertEqual(loaded?.snapshot(), snapshot)
    }

    func testRepositoryLoadKeepsProjectsIndependent() {
        let defaults = makeUserDefaults()
        let repository = BeadWorkspaceStateRepository(userDefaults: defaults)
        let projectA = URL(fileURLWithPath: "/tmp/BeadazzleTests/ProjectA")
        let projectB = URL(fileURLWithPath: "/tmp/BeadazzleTests/ProjectB")

        var snapshotA = makeSnapshot()
        snapshotA.searchText = "alpha"
        var snapshotB = makeSnapshot()
        snapshotB.searchText = "beta"

        repository.save(BeadWorkspaceStatePayload(snapshot: snapshotA), projectURL: projectA)
        repository.save(BeadWorkspaceStatePayload(snapshot: snapshotB), projectURL: projectB)

        XCTAssertEqual(repository.load(projectURL: projectA)?.searchText, "alpha")
        XCTAssertEqual(repository.load(projectURL: projectB)?.searchText, "beta")
    }

    func testRepositoryReturnsNilAndPreservesRecoveryForCorruptData() {
        let defaults = makeUserDefaults()
        let repository = BeadWorkspaceStateRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/BeadazzleTests/ProjectA")
        let key = BeadazzlePreferenceKeys.workspaceState(projectURL: projectURL)
        defaults.set(Data("not valid json".utf8), forKey: key)

        XCTAssertNil(repository.load(projectURL: projectURL))
        XCTAssertNotNil(defaults.data(forKey: "\(key).Recovery"))
    }

    func testRepositoryReturnsNilAndPreservesRecoveryForNewerVersion() throws {
        let defaults = makeUserDefaults()
        let repository = BeadWorkspaceStateRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/BeadazzleTests/ProjectA")
        let key = BeadazzlePreferenceKeys.workspaceState(projectURL: projectURL)
        let futureVersion = BeadWorkspaceStatePayload.currentVersion + 1
        let data = try JSONSerialization.data(withJSONObject: ["version": futureVersion])
        defaults.set(data, forKey: key)

        XCTAssertNil(repository.load(projectURL: projectURL))
        XCTAssertNotNil(defaults.data(forKey: "\(key).Recovery"))
    }

    func testRepositoryResetRemovesKeyAndArchivesRecovery() {
        let defaults = makeUserDefaults()
        let repository = BeadWorkspaceStateRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/BeadazzleTests/ProjectA")
        let key = BeadazzlePreferenceKeys.workspaceState(projectURL: projectURL)
        repository.save(BeadWorkspaceStatePayload(snapshot: makeSnapshot()), projectURL: projectURL)

        repository.reset(projectURL: projectURL)

        XCTAssertNil(defaults.data(forKey: key))
        let archivedKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(key).Recovery.") }
        XCTAssertFalse(archivedKeys.isEmpty)
    }

    // MARK: - Helpers

    private func makeSnapshot() -> BeadWorkspaceSnapshot {
        var outline = BeadOutlineSelectionState()
        outline.setExpansion(issueID: "bd-1", isExpanded: true)
        outline.setExpansion(issueID: "bd-2", isExpanded: false)

        var draft = IssueDraft.blank(defaultType: "task", defaultStatus: "open")
        draft.title = "Draft in progress"
        draft.priority = 1
        draft.labelsText = "wip"

        return BeadWorkspaceSnapshot(
            bookmark: .inProgress,
            activeSavedViewID: nil,
            sourceSavedViewID: nil,
            savedViewOrdering: nil,
            selectedIDs: ["bd-1", "bd-3"],
            fullPageDetailIssueID: "bd-3",
            searchText: "query text",
            statusFilters: ["open", "in_progress"],
            typeFilters: ["task"],
            priorityFilters: [1, 2],
            labelFilters: ["urgent"],
            advancedPredicate: nil,
            sort: .updated,
            sortDirection: .descending,
            issueListMode: .flat,
            outlineState: outline,
            creationDraft: draft
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadazzleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
