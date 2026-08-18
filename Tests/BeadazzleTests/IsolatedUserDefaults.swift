import Foundation
import XCTest

extension XCTestCase {
    /// A `UserDefaults` suite private to one test, left behind on disk by neither the test
    /// nor the run it belongs to.
    ///
    /// - Parameter name: Names the owner inside the suite, so a file caught in flight says
    ///   which tests made it. Defaults to the test class, which is what you want.
    func makeIsolatedUserDefaults(named name: String? = nil) -> UserDefaults {
        let owner = name ?? String(describing: type(of: self))
        let suiteName = IsolatedUserDefaultsSweeper.shared.registerSuite(named: owner)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            IsolatedUserDefaultsSweeper.discardSuite(named: suiteName)
        }
        return defaults
    }
}

/// Removes the preference files test suites would otherwise leave in `~/Library/Preferences`.
///
/// `removePersistentDomain(forName:)` only empties a suite: `cfprefsd` keeps its backing
/// plist, so a per-test suite name left one file behind for every test of every run — over a
/// hundred thousand had piled up before this existed. Deleting the file from a teardown block
/// is not enough on its own, because work that outlives its test — a debounced workspace
/// write, a definitions cache refresh — writes to the suite afterwards and `cfprefsd`
/// recreates the file, sometimes after the run itself has finished.
///
/// So the run sweeps at both ends. When the bundle finishes it discards every suite the run
/// created; when the next run starts it deletes whatever landed after that — including
/// anything a run that crashed never got to clean up. Residue is bounded at one run's worth
/// instead of accumulating forever.
final class IsolatedUserDefaultsSweeper: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = IsolatedUserDefaultsSweeper()

    /// Marks a suite as an isolated test suite. Every one carries it, so the sweeps never
    /// need an allowlist of test names to recognize their own leftovers.
    private static let suitePrefix = "BeadazzleTestDefaults."

    private let lock = NSLock()
    private var suiteNames: Set<String> = []
    private let startedAt = Date()

    private override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        // Not `testBundleWillStart`: this observer registers on first use, which is already
        // inside the first test. Older files are the previous run's — a concurrent test
        // process writes newer ones, so its live suites are never swept out from under it.
        sweepLeftoverPreferenceFiles(modifiedBefore: startedAt)
    }

    func registerSuite(named name: String) -> String {
        let suiteName = "\(Self.suitePrefix)\(name).\(UUID().uuidString)"
        lock.lock()
        suiteNames.insert(suiteName)
        lock.unlock()
        return suiteName
    }

    static func discardSuite(named suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        // Flush before deleting: `cfprefsd` writes lazily, and a pending write would
        // otherwise recreate the file moments after it is gone.
        CFPreferencesAppSynchronize(suiteName as CFString)
        UserDefaults.standard.removeSuite(named: suiteName)
        guard let fileURL = preferencesFileURL(forSuite: suiteName) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Guarded so a malformed suite name can never turn a sweep into a path traversal that
    /// deletes a real application's preferences.
    private static func preferencesFileURL(forSuite suiteName: String) -> URL? {
        guard suiteName.hasPrefix(suitePrefix), !suiteName.contains("/") else { return nil }
        return preferencesDirectoryURL.appendingPathComponent("\(suiteName).plist")
    }

    private static var preferencesDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    private func sweepLeftoverPreferenceFiles(modifiedBefore cutoff: Date) {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.preferencesDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for fileURL in contents ?? [] where fileURL.lastPathComponent.hasPrefix(Self.suitePrefix) {
            let modifiedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modifiedAt, modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        lock.lock()
        let names = suiteNames
        lock.unlock()
        for suiteName in names {
            Self.discardSuite(named: suiteName)
        }
    }
}
