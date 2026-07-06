import Foundation

struct RecentProject: Identifiable, Equatable, Hashable {
    let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    var id: String {
        normalizedPath
    }

    var name: String {
        url.lastPathComponent
    }

    var path: String {
        normalizedPath
    }

    var normalizedPath: String {
        Self.normalizedPath(for: url)
    }

    static func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
