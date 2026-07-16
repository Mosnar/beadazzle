import XCTest
@testable import Beadazzle

final class BeadsInteractionsReaderTests: XCTestCase {
    func testParsesFieldChangeEventsWithReasonAndFractionalSecondTimestamps() throws {
        // Real `bd` output: fractional seconds vary in width (.590194Z vs .83579Z).
        let jsonl = """
        {"id":"int-1","kind":"field_change","created_at":"2026-07-03T20:24:02.590194Z","actor":"Beadazzle","issue_id":"bd-a","extra":{"field":"status","new_value":"closed","old_value":"open","reason":"Shipped it."}}
        {"id":"int-2","kind":"field_change","created_at":"2026-07-03T20:24:02.83579Z","actor":"Beadazzle","issue_id":"bd-b","extra":{"field":"status","new_value":"in_progress","old_value":"open"}}
        """
        let events = BeadsInteractionsReader().events(fromJSONLData: Data(jsonl.utf8))

        let eventA = try XCTUnwrap(events["bd-a"]?.first)
        XCTAssertEqual(eventA.id, "int-1")
        XCTAssertEqual(eventA.kind, "field_change")
        XCTAssertEqual(eventA.actor, "Beadazzle")
        XCTAssertEqual(eventA.field, "status")
        XCTAssertEqual(eventA.oldValue, "open")
        XCTAssertEqual(eventA.newValue, "closed")
        XCTAssertEqual(eventA.reason, "Shipped it.")
        XCTAssertNotNil(eventA.createdAt)

        let eventB = try XCTUnwrap(events["bd-b"]?.first)
        XCTAssertNil(eventB.reason)
        XCTAssertNotNil(eventB.createdAt)
    }

    func testSkipsMalformedLinesAndEventsWithoutIssueID() {
        let jsonl = """
        not json at all
        {"id":"int-1","kind":"field_change","created_at":"2026-07-03T20:24:02Z","extra":{}}
        {"id":"int-2","kind":"field_change","created_at":"2026-07-03T20:24:03Z","issue_id":"bd-a","extra":{"field":"priority","old_value":"2","new_value":"1"}}
        """
        let events = BeadsInteractionsReader().events(fromJSONLData: Data(jsonl.utf8))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events["bd-a"]?.map(\.id), ["int-2"])
    }

    func testSortsEventsPerIssueOldestFirst() {
        let jsonl = """
        {"id":"int-2","kind":"field_change","created_at":"2026-07-05T10:00:00Z","issue_id":"bd-a","extra":{"field":"status","old_value":"in_progress","new_value":"closed"}}
        {"id":"int-1","kind":"field_change","created_at":"2026-07-03T10:00:00Z","issue_id":"bd-a","extra":{"field":"status","old_value":"open","new_value":"in_progress"}}
        """
        let events = BeadsInteractionsReader().events(fromJSONLData: Data(jsonl.utf8))

        XCTAssertEqual(events["bd-a"]?.map(\.id), ["int-1", "int-2"])
    }

    func testPreservesMicrosecondPrecisionAndSourceOrderForTies() throws {
        let jsonl = """
        {"id":"int-late","kind":"field_change","created_at":"2026-07-03T20:24:02.590195Z","issue_id":"bd-a","extra":{"field":"priority","old_value":"2","new_value":"1"}}
        {"id":"int-early","kind":"field_change","created_at":"2026-07-03T20:24:02.590194Z","issue_id":"bd-a","extra":{"field":"priority","old_value":"3","new_value":"2"}}
        {"id":"z-source-first","kind":"field_change","created_at":"2026-07-03T20:24:03.000000Z","issue_id":"bd-a","extra":{"field":"assignee","new_value":"one"}}
        {"id":"a-source-second","kind":"field_change","created_at":"2026-07-03T20:24:03.000000Z","issue_id":"bd-a","extra":{"field":"assignee","old_value":"one","new_value":"two"}}
        """
        let events = try XCTUnwrap(BeadsInteractionsReader().events(fromJSONLData: Data(jsonl.utf8))["bd-a"])

        XCTAssertEqual(events.map(\.id), [
            "int-early", "int-late", "z-source-first", "a-source-second"
        ])
        let early = try XCTUnwrap(events.first?.createdAt)
        let late = try XCTUnwrap(events.dropFirst().first?.createdAt)
        XCTAssertEqual(late.timeIntervalSince(early), 0.000001, accuracy: 0.0000001)
    }

    func testMissingFileYieldsNoEvents() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionsReaderTests-\(UUID().uuidString)", isDirectory: true)
        let events = try await BeadActivityHistoryRepository().events(
            projectURL: projectURL,
            issueID: "bd-a"
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testSnapshotReaderDoesNotPutInteractionsOnProjectLoadPath() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionsSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try #"{"id":"bd-a","title":"One","status":"open","priority":2,"issue_type":"task"}"#
            .write(to: beadsURL.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)
        // Even a malformed activity log cannot delay or fail the issue snapshot.
        try "not valid JSON at all\n"
            .write(to: beadsURL.appendingPathComponent("interactions.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = try BeadsSnapshotReader().loadSnapshot(projectURL: projectURL)

        XCTAssertEqual(snapshot.issues.map(\.id), ["bd-a"])
    }

    func testRepositoryReadsOnlyRequestedIssueAndTailsAppends() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionsReaderTests-\(UUID().uuidString)", isDirectory: true)
        let directory = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let initial = """
        {"id":"int-1","kind":"field_change","created_at":"2026-07-03T20:24:02Z","actor":"ransom","issue_id":"bd-a","extra":{"field":"status","old_value":"open","new_value":"closed"}}
        {"id":"other-1","kind":"field_change","created_at":"2026-07-03T20:24:03Z","issue_id":"bd-b","extra":{"field":"priority","old_value":"2","new_value":"1"}}
        """
        let logURL = directory.appendingPathComponent("interactions.jsonl")
        try Data((initial + "\n").utf8).write(to: logURL)
        let repository = BeadActivityHistoryRepository()

        var events = try await repository.events(
            projectURL: projectURL,
            issueID: "bd-a",
            validIssueIDs: ["bd-a", "bd-b"],
            issueSetRevision: 1
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.actor, "ransom")

        let appended = #"{"id":"int-2","kind":"field_change","created_at":"2026-07-03T20:24:04Z","issue_id":"bd-a","extra":{"field":"status","old_value":"closed","new_value":"open"}}"# + "\n"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        events = try await repository.events(
            projectURL: projectURL,
            issueID: "bd-a",
            validIssueIDs: ["bd-a", "bd-b"],
            issueSetRevision: 1
        )
        XCTAssertEqual(events.map(\.id), ["int-1", "int-2"])
    }

    func testLargeLogRetainsOnlyRequestedIssueEvents() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionsScaleTests-\(UUID().uuidString)", isDirectory: true)
        let directory = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        var lines: [String] = []
        lines.reserveCapacity(10_001)
        for index in 0..<10_000 {
            lines.append("""
            {"id":"other-\(index)","kind":"field_change","created_at":"2026-07-03T20:24:02Z","issue_id":"bd-other-\(index)","extra":{"field":"priority","old_value":"2","new_value":"1"}}
            """)
        }
        lines.append(#"{"id":"selected","kind":"field_change","created_at":"2026-07-03T20:24:03Z","issue_id":"bd-selected","extra":{"field":"status","old_value":"open","new_value":"closed"}}"#)
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent("interactions.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let events = try await BeadActivityHistoryRepository().events(
            projectURL: projectURL,
            issueID: "bd-selected",
            validIssueIDs: ["bd-selected"],
            issueSetRevision: 1
        )
        XCTAssertEqual(events.map(\.id), ["selected"])
    }

    func testIssueSetRevisionRebuildsFilteredIndexForNewlyVisibleIssue() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InteractionsIssueSetTests-\(UUID().uuidString)", isDirectory: true)
        let directory = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let log = """
        {"id":"int-a","kind":"field_change","created_at":"2026-07-03T20:24:02Z","issue_id":"bd-a","extra":{"field":"priority","old_value":"2","new_value":"1"}}
        {"id":"int-b","kind":"field_change","created_at":"2026-07-03T20:24:03Z","issue_id":"bd-b","extra":{"field":"assignee","new_value":"ransom"}}
        """
        try log.write(
            to: directory.appendingPathComponent("interactions.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let repository = BeadActivityHistoryRepository()

        let initiallyHidden = try await repository.events(
            projectURL: projectURL,
            issueID: "bd-b",
            validIssueIDs: ["bd-a"],
            issueSetRevision: 1
        )
        XCTAssertTrue(initiallyHidden.isEmpty)

        let newlyVisible = try await repository.events(
            projectURL: projectURL,
            issueID: "bd-b",
            validIssueIDs: ["bd-a", "bd-b"],
            issueSetRevision: 2
        )
        XCTAssertEqual(newlyVisible.map(\.id), ["int-b"])
    }
}
