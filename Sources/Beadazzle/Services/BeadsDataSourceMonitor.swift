import Darwin
import Foundation

final class BeadsDataSourceMonitor {
    enum Role: Hashable, Sendable {
        case activeSource
        case legacySQLite
        case beadsDirectory
        case exportState
        case lastTouched
    }

    struct Event: Equatable, Sendable {
        var roles: Set<Role>
    }

    fileprivate struct WatchedPath {
        var url: URL
        var role: Role
    }

    private let watchedPaths: [WatchedPath]
    private let debounce: TimeInterval
    private let callback: (Event) -> Void
    private let queue = DispatchQueue(label: "com.beadazzle.data-source-monitor")
    private var watches: [PathWatch] = []
    private var pendingCallback: DispatchWorkItem?
    private var pendingRoles: Set<Role> = []
    private var isStopped = false

    init(
        projectURL: URL,
        source: BeadsDataSource,
        debounce: TimeInterval = 0.35,
        callback: @escaping (Event) -> Void
    ) {
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        let sqliteURL = beadsURL.appendingPathComponent("beads.db")
        self.watchedPaths = Self.uniquePaths([
            WatchedPath(url: source.url, role: .activeSource),
            WatchedPath(url: sqliteURL, role: .legacySQLite),
            WatchedPath(url: beadsURL, role: .beadsDirectory),
            WatchedPath(url: beadsURL.appendingPathComponent("export-state.json"), role: .exportState),
            WatchedPath(url: beadsURL.appendingPathComponent("last-touched"), role: .lastTouched)
        ])
        self.debounce = debounce
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.watches.isEmpty, !self.isStopped else { return }
            self.watchExistingPaths()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.isStopped = true
            self.pendingCallback?.cancel()
            self.pendingCallback = nil
            self.pendingRoles = []
            for watch in self.watches {
                watch.cancel()
            }
            self.watches = []
        }
    }

    /// Content-change events we care about. Deliberately excludes `.attrib`: `bd`
    /// invocations (including the app's own `--readonly` reads) touch `beads.db`'s
    /// attributes without changing its contents, and watching `.attrib` turned every
    /// read into a spurious "data changed" event — the app's reads re-triggered its
    /// own monitor, driving a runaway reload → `bd` → reload loop. `.delete`/`.rename`
    /// still catch atomic replaces (e.g. `bd export` rewriting `issues.jsonl`).
    private static let eventMask: DispatchSource.FileSystemEvent = [
        .write,
        .extend,
        .delete,
        .rename,
        .revoke
    ]

    /// Events that mean the watched inode is gone (atomically replaced/unlinked). The
    /// `O_EVTONLY` descriptor now points at a dead inode and would never fire again, so
    /// we must re-open a fresh watch on the path.
    private static let replacementEvents: DispatchSource.FileSystemEvent = [.delete, .rename, .revoke]

    private func watchExistingPaths() {
        for path in watchedPaths where !isWatching(path.url) {
            watch(path)
        }
    }

    private func isWatching(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return watches.contains { $0.url.standardizedFileURL.path == path }
    }

    private func watch(_ path: WatchedPath) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.url.path, isDirectory: &isDirectory) else { return }

        let descriptor = open(path.url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.eventMask,
            queue: queue
        )
        let watch = PathWatch(source: source, path: path)
        source.setEventHandler { [weak self, weak watch] in
            guard let self else { return }
            let flags = source.data
            if watch?.role == .beadsDirectory {
                self.watchExistingPaths()
            }
            self.scheduleCallback(role: watch?.role)
            if !flags.isDisjoint(with: Self.replacementEvents), let watch {
                self.rearm(watch)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        watches.append(watch)
        source.resume()
    }

    /// Re-establishes a watch after its file was atomically replaced: the old descriptor
    /// points at a dead inode and will never fire again. The replacement may not have
    /// landed yet, so poll briefly (up to ~0.6s) for the path to reappear before giving up.
    private func rearm(_ watch: PathWatch) {
        guard !isStopped, !watch.isCancelled else { return }
        watch.cancel()
        watches.removeAll { $0 === watch }
        scheduleReopen(path: WatchedPath(url: watch.url, role: watch.role), attempt: 0)
    }

    private func scheduleReopen(path: WatchedPath, attempt: Int) {
        guard !isStopped, attempt < 6 else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.isStopped else { return }
            if FileManager.default.fileExists(atPath: path.url.path) {
                self.watch(path)
            } else {
                self.scheduleReopen(path: path, attempt: attempt + 1)
            }
        }
    }

    private func scheduleCallback(role: Role?) {
        guard !isStopped else { return }
        if let role {
            pendingRoles.insert(role)
        }
        pendingCallback?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            let roles = self.pendingRoles
            self.pendingRoles = []
            self.callback(Event(roles: roles))
        }
        pendingCallback = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private static func uniquePaths(_ paths: [WatchedPath]) -> [WatchedPath] {
        var seen: Set<String> = []
        var result: [WatchedPath] = []
        for watchedPath in paths {
            let path = watchedPath.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(watchedPath)
        }
        return result
    }
}

private final class PathWatch {
    private let source: DispatchSourceFileSystemObject
    let url: URL
    let role: BeadsDataSourceMonitor.Role
    private(set) var isCancelled = false

    init(source: DispatchSourceFileSystemObject, path: BeadsDataSourceMonitor.WatchedPath) {
        self.source = source
        self.url = path.url
        self.role = path.role
    }

    deinit {
        cancel()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        source.cancel()
    }
}
