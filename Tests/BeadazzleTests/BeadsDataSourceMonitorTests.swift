import XCTest
@testable import Beadazzle

final class BeadsDataSourceMonitorTests: XCTestCase {
    /// The runaway-reload bug was the monitor treating `.attrib` events (which the app's
    /// own `bd` reads generate) as data changes. This locks in that attribute-only changes
    /// are ignored while real content writes still trigger a reload.
    func testIgnoresAttributeOnlyChangesButReactsToContentWrites() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }

        let fileURL = beadsURL.appendingPathComponent("issues.jsonl")
        try "initial\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let source = BeadsDataSource(
            kind: .jsonl,
            url: fileURL,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        )

        let callbacks = CallbackCounter()
        let monitor = BeadsDataSourceMonitor(projectURL: projectURL, source: source, debounce: 0.05) { _ in
            callbacks.increment()
        }
        monitor.start()
        addTeardownBlock { monitor.stop() }

        // Let the watch establish (start() dispatches asynchronously).
        Thread.sleep(forTimeInterval: 0.3)

        // Attribute-only change (bumps mtime, no content change) — must NOT reload.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(callbacks.value, 0, "attribute-only change must not trigger a reload")

        // Real content write — must reload exactly once (after the debounce).
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("more\n".utf8))
        try handle.close()

        let deadline = Date().addingTimeInterval(2)
        while callbacks.value == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertGreaterThanOrEqual(callbacks.value, 1, "a content write must trigger a reload")
    }

    func testReportsExportStateMarkerEventsWithoutTouchingActiveSnapshot() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }

        let fileURL = beadsURL.appendingPathComponent("issues.jsonl")
        try "initial\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let markerURL = beadsURL.appendingPathComponent("export-state.json")
        try #"{"timestamp":"old"}"#.write(to: markerURL, atomically: true, encoding: .utf8)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let source = BeadsDataSource(
            kind: .jsonl,
            url: fileURL,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        )

        let events = MonitorEventRecorder()
        let monitor = BeadsDataSourceMonitor(projectURL: projectURL, source: source, debounce: 0.05) { event in
            events.append(event)
        }
        monitor.start()
        addTeardownBlock { monitor.stop() }

        Thread.sleep(forTimeInterval: 0.3)
        try #"{"timestamp":"new","issues":1}"#.write(to: markerURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(2)
        while !events.containsRole(.exportState), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertTrue(events.containsRole(.exportState), "export marker changes should report marker-only freshness events")
        XCTAssertFalse(events.containsRole(.activeSource), "marker-only changes must not be reported as active snapshot changes")
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class MonitorEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BeadsDataSourceMonitor.Event] = []

    func append(_ event: BeadsDataSourceMonitor.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func containsRole(_ role: BeadsDataSourceMonitor.Role) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { $0.roles.contains(role) }
    }
}
