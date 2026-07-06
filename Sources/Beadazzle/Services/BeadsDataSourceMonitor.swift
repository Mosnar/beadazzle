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

    private func watch(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let mask: DispatchSource.FileSystemEvent = [
            .write,
            .extend,
            .attrib,
            .delete,
            .rename,
            .link,
            .revoke
        ]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleCallback()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        watches.append(PathWatch(source: source))
        source.resume()
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
    private var isCancelled = false

    init(source: DispatchSourceFileSystemObject) {
        self.source = source
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
