import Foundation

struct BeadsDataSourceDiscovery {
    static let preferredJSONLNames = ["issues.jsonl", "beads.jsonl", "beads.base.jsonl"]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover(projectURL: URL, beadsDirectoryURL: URL? = nil) throws -> BeadsDataSource {
        let beadsURL = beadsDirectoryURL
            ?? projectURL.appendingPathComponent(".beads", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: beadsURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BeadError.projectMissingDataSource(projectURL)
        }

        for fileName in Self.preferredJSONLNames {
            let jsonlURL = beadsURL.appendingPathComponent(fileName)
            if let jsonlSource = regularFileDataSource(url: jsonlURL, kind: .jsonl, allowsEmpty: true) {
                return jsonlSource
            }
        }

        throw BeadError.projectMissingDataSource(projectURL)
    }
    private func regularFileDataSource(url: URL, kind: BeadsDataSourceKind, allowsEmpty: Bool = false) -> BeadsDataSource? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return nil
        }

        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard allowsEmpty || size > 0 else { return nil }

        return BeadsDataSource(
            kind: kind,
            url: url,
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }
}
