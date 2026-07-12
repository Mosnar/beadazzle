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

        repository.save([view], projectURL: projectURL)
        let result = repository.load(projectURL: projectURL)

        XCTAssertEqual(result.views.count, 1)
        XCTAssertEqual(result.views[0].name, "Focus")
        XCTAssertEqual(result.views[0].symbolName, BeadSavedViewSymbols.normalized(view.symbolName))
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

    private func makeSavedView() -> BeadSavedView {
        BeadSavedView(
            id: UUID(),
            name: "Focus",
            symbolName: "bookmark",
            filter: BeadSavedViewFilter(
                basePreset: .all,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: "",
                sort: .priority,
                sortDirection: .ascending
            )
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
