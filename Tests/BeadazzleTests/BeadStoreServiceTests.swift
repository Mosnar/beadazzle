import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadSavedViewRepositoryTests: XCTestCase {
    func testFolderRoundTripNormalizesPresentationFieldsAndIssueIDs() {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-round-trip")
        var view = BeadSavedView(
            id: UUID(),
            name: "Focus",
            symbolName: "folder",
            content: .folder(BeadFolderBookmark(
                orderedIssueIDs: ["bd-1", " bd-1 ", "", "bd-2"]
            ))
        )
        view.name = "  Focus  "
        view.symbolName = "not.a.real.saved.view.symbol"

        repository.save([view], projectURL: projectURL)
        let result = repository.load(projectURL: projectURL)

        XCTAssertEqual(result.views.count, 1)
        XCTAssertEqual(result.views[0].name, "Focus")
        XCTAssertEqual(result.views[0].symbolName, BeadSavedViewSymbols.normalized(view.symbolName))
        XCTAssertEqual(result.views[0].folder?.orderedIssueIDs, ["bd-1", "bd-2"])
        XCTAssertTrue(result.rebuildsCounts)
        XCTAssertFalse(result.isCorrupt)
    }

    func testCorruptPayloadIsPreservedForRecovery() {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-corrupt")
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        let corruptData = Data("not-json".utf8)
        defaults.set(corruptData, forKey: key)

        let result = repository.load(projectURL: projectURL)

        XCTAssertTrue(result.isCorrupt)
        XCTAssertEqual(result.recoveryIssueCount, 1)
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), corruptData)
    }

    func testExplicitResetArchivesCurrentPayloadEvenWhenRecoveryAlreadyExists() throws {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-reset-archive")
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        let earlierRecovery = Data("earlier".utf8)
        defaults.set(earlierRecovery, forKey: "\(key).Recovery")
        repository.save([makeSavedView()], projectURL: projectURL)
        let currentPayload = try XCTUnwrap(defaults.data(forKey: key))

        repository.reset(projectURL: projectURL)

        XCTAssertNil(defaults.data(forKey: key))
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), earlierRecovery)
        let archivedPayloads = defaults.dictionaryRepresentation().compactMap { entryKey, value -> Data? in
            guard entryKey.hasPrefix("\(key).Recovery."), let data = value as? Data else { return nil }
            return data
        }
        XCTAssertTrue(archivedPayloads.contains(currentPayload))
    }

    func testMalformedCurrentPayloadPreservesValidSiblings() throws {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-current-recovery")
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        let view = makeSavedView()
        let payload = BeadSavedViewsPayload(views: [view])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        var views = try XCTUnwrap(object["views"] as? [[String: Any]])
        views.append(["kind": "future-bookmark"])
        object["views"] = views
        let damagedData = try JSONSerialization.data(withJSONObject: object)
        defaults.set(damagedData, forKey: key)

        let result = repository.load(projectURL: projectURL)

        XCTAssertEqual(result.recoveryIssueCount, 1)
        XCTAssertEqual(result.views, [view])
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), damagedData)
    }

    func testVersionOneMigrationFlattensOrganizationAndDiscardsDormantManualMembership() throws {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-version-one-migration")
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        let query = BeadSavedViewQuery(
            basePreset: .all,
            statusFilters: ["open"],
            typeFilters: [],
            priorityFilters: [],
            labelFilters: [],
            searchText: ""
        )
        let fallbackSort = BeadSavedViewSort(field: .updated, direction: .descending)
        let first = LegacySavedViewFixture(
            id: UUID(),
            name: "First",
            symbolName: "bookmark",
            query: query,
            ordering: .manual(BeadSavedViewManualOrdering(
                issueIDs: ["bd-3", "bd-1"],
                fallback: fallbackSort
            ))
        )
        let second = LegacySavedViewFixture(
            id: UUID(),
            name: "Second",
            symbolName: "star",
            query: query,
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
        let legacyPayload = LegacySavedViewsPayloadFixture(rootNodes: [
            .folder(
                id: UUID(),
                name: "Planning",
                children: [
                    .view(first),
                    .folder(id: UUID(), name: "Nested", children: [.view(second)])
                ]
            )
        ])
        let legacyData = try JSONEncoder().encode(legacyPayload)
        defaults.set(legacyData, forKey: key)

        let result = repository.load(projectURL: projectURL)

        XCTAssertEqual(result.views.map(\.id), [first.id, second.id])
        XCTAssertEqual(result.views.map(\.smartQuery), [query, query])
        XCTAssertEqual(result.views[0].savedSort, fallbackSort)
        XCTAssertEqual(
            result.views[1].savedSort,
            BeadSavedViewSort(field: .priority, direction: .ascending)
        )
        XCTAssertTrue(result.views.allSatisfy { !$0.isFolder })
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), legacyData)

        let migratedData = try XCTUnwrap(defaults.data(forKey: key))
        let migrated = try JSONDecoder().decode(BeadSavedViewsPayload.self, from: migratedData)
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.views, result.views)
    }

    private func makeSavedView() -> BeadSavedView {
        BeadSavedView(
            id: UUID(),
            name: "Focus",
            symbolName: "bookmark",
            query: BeadSavedViewQuery(
                basePreset: .all,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: ""
            ),
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadSavedViewRepositoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

}

private struct LegacySavedViewsPayloadFixture: Encodable {
    var version = 1
    var rootNodes: [LegacySavedViewNodeFixture]
}

private struct LegacySavedViewFixture: Encodable {
    var id: UUID
    var name: String
    var symbolName: String
    var query: BeadSavedViewQuery
    var ordering: BeadSavedViewOrdering
}

private indirect enum LegacySavedViewNodeFixture: Encodable {
    case folder(id: UUID, name: String, children: [Self])
    case view(LegacySavedViewFixture)

    private enum CodingKeys: String, CodingKey {
        case kind
        case folder
        case view
    }

    private enum FolderKeys: String, CodingKey {
        case id
        case name
        case children
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let id, let name, let children):
            try container.encode("folder", forKey: .kind)
            var folder = container.nestedContainer(keyedBy: FolderKeys.self, forKey: .folder)
            try folder.encode(id, forKey: .id)
            try folder.encode(name, forKey: .name)
            try folder.encode(children, forKey: .children)
        case .view(let view):
            try container.encode("view", forKey: .kind)
            try container.encode(view, forKey: .view)
        }
    }
}

@MainActor
final class BeadMutationWriteQueueTests: XCTestCase {
    func testWritesRemainOrdered() async throws {
        let queue = BeadMutationWriteQueue()
        let recorder = WriteRecorder()
        let gate = WriteGate()

        let first = Task {
            try await queue.enqueue {
                await gate.pause()
                await recorder.append(1)
            }
        }
        await gate.waitUntilPaused()
        let second = Task {
            try await queue.enqueue {
                await recorder.append(2)
            }
        }
        await gate.release()

        try await first.value
        try await second.value
        let values = await recorder.values
        XCTAssertEqual(values, [1, 2])
    }

    func testFailedWriteDoesNotPoisonQueue() async throws {
        let queue = BeadMutationWriteQueue()
        let recorder = WriteRecorder()

        do {
            try await queue.enqueue { throw WriteFailure.expected }
            XCTFail("Expected the first write to fail")
        } catch WriteFailure.expected {
            // Expected.
        }

        try await queue.enqueue { await recorder.append(2) }
        let values = await recorder.values
        XCTAssertEqual(values, [2])
    }

    func testInvalidationPreventsAWaitingWriteFromStarting() async throws {
        let queue = BeadMutationWriteQueue()
        let recorder = WriteRecorder()
        let gate = WriteGate()

        let first = Task {
            try await queue.enqueue {
                await gate.pause()
                await recorder.append(1)
            }
        }
        await gate.waitUntilPaused()
        let second = Task {
            try await queue.enqueue {
                await recorder.append(2)
            }
        }
        await Task.yield()
        queue.invalidatePending()
        await gate.release()

        try await first.value
        do {
            try await second.value
            XCTFail("Expected the queued write to be invalidated")
        } catch is CancellationError {
            // Expected.
        }
        let values = await recorder.values
        XCTAssertEqual(values, [1])
    }
}

private actor WriteRecorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

private actor WriteGate {
    private var isPaused = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        while !isPaused {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum WriteFailure: Error {
    case expected
}
