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
        let monitor = BeadsDataSourceMonitor(projectURL: projectURL, source: source, debounce: 0.05) {
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
