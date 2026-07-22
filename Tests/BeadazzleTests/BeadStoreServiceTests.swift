import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadSavedViewRepositoryTests: XCTestCase {
    func testRoundTripNormalizesPresentationFields() {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-round-trip")
        var view = makeSavedView()
        view.name = "  Focus  "
        view.symbolName = "not.a.real.saved.view.symbol"
        view.ordering = .manual(BeadSavedViewManualOrdering(
            issueIDs: ["bd-1", " bd-1 ", "", "bd-2"],
            fallback: BeadSavedViewSort(field: .updated, direction: .descending)
        ))

        repository.save(BeadSavedViewTree(rootNodes: [.view(view)]), projectURL: projectURL)
        let result = repository.load(projectURL: projectURL)

        XCTAssertEqual(result.views.count, 1)
        XCTAssertEqual(result.views[0].name, "Focus")
        XCTAssertEqual(result.views[0].symbolName, BeadSavedViewSymbols.normalized(view.symbolName))
        guard case .manual(let ordering) = result.views[0].ordering else {
            return XCTFail("Expected manual ordering")
        }
        XCTAssertEqual(ordering.issueIDs, ["bd-1", "bd-2"])
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
        repository.save(BeadSavedViewTree(rootNodes: [.view(makeSavedView())]), projectURL: projectURL)
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

    func testMalformedNestedNodePreservesFolderAndValidSiblings() throws {
        let defaults = makeUserDefaults()
        let repository = BeadSavedViewRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/repository-nested-recovery")
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        let view = makeSavedView()
        let payload = BeadSavedViewsPayload(rootNodes: [
            .folder(BeadSavedViewFolder(id: UUID(), name: "  Planning  ", children: [.view(view)]))
        ])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        var rootNodes = try XCTUnwrap(object["rootNodes"] as? [[String: Any]])
        var folder = try XCTUnwrap(rootNodes[0]["folder"] as? [String: Any])
        var children = try XCTUnwrap(folder["children"] as? [[String: Any]])
        children.append(["kind": "future-node"])
        folder["children"] = children
        rootNodes[0]["folder"] = folder
        object["rootNodes"] = rootNodes
        let damagedData = try JSONSerialization.data(withJSONObject: object)
        defaults.set(damagedData, forKey: key)

        let result = repository.load(projectURL: projectURL)

        XCTAssertEqual(result.recoveryIssueCount, 1)
        XCTAssertEqual(result.views, [view])
        guard case .folder(let recoveredFolder) = result.rootNodes.first else {
            return XCTFail("Expected recovered folder")
        }
        XCTAssertEqual(recoveredFolder.name, "Planning")
        XCTAssertEqual(recoveredFolder.children, [.view(view)])
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), damagedData)
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
