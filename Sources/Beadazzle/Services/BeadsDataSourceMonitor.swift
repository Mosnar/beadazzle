import Darwin
import Foundation

final class BeadsDataSourceMonitor {
    private let watchedURLs: [URL]
    private let debounce: TimeInterval
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "com.beadazzle.data-source-monitor")
    private var watches: [PathWatch] = []
    private var pendingCallback: DispatchWorkItem?
    private var isStopped = false

    init(
        projectURL: URL,
        source: BeadsDataSource,
        debounce: TimeInterval = 0.35,
        callback: @escaping () -> Void
    ) {
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        let sqliteURL = beadsURL.appendingPathComponent("beads.db")
        self.watchedURLs = Self.uniqueURLs([source.url, sqliteURL, beadsURL])
        self.debounce = debounce
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.watches.isEmpty, !self.isStopped else { return }
            for url in self.watchedURLs {
                self.watch(url)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.isStopped = true
            self.pendingCallback?.cancel()
            self.pendingCallback = nil
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

    private func watch(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.eventMask,
            queue: queue
        )
        let watch = PathWatch(source: source, url: url)
        source.setEventHandler { [weak self, weak watch] in
            guard let self else { return }
            let flags = source.data
            self.scheduleCallback()
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
        scheduleReopen(url: watch.url, attempt: 0)
    }

    private func scheduleReopen(url: URL, attempt: Int) {
        guard !isStopped, attempt < 6 else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.isStopped else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                self.watch(url)
            } else {
                self.scheduleReopen(url: url, attempt: attempt + 1)
            }
        }
    }

    private func scheduleCallback() {
        guard !isStopped else { return }
        pendingCallback?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.callback()
        }
        pendingCallback = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(url)
        }
        return result
    }
}

private final class PathWatch {
    private let source: DispatchSourceFileSystemObject
    let url: URL
    private(set) var isCancelled = false

    init(source: DispatchSourceFileSystemObject, url: URL) {
        self.source = source
        self.url = url
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
