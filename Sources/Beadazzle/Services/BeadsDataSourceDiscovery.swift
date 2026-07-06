import CSQLite
import Foundation

struct BeadsDataSourceDiscovery {
    static let preferredJSONLNames = ["issues.jsonl", "beads.jsonl", "beads.base.jsonl"]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover(projectURL: URL) throws -> BeadsDataSource {
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: beadsURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BeadError.projectMissingDataSource(projectURL)
        }

        let sqliteURL = beadsURL.appendingPathComponent("beads.db")
        if let sqliteSource = sqliteDataSourceIfPopulated(sqliteURL) {
            return sqliteSource
        }

        for fileName in Self.preferredJSONLNames {
            let jsonlURL = beadsURL.appendingPathComponent(fileName)
            if let jsonlSource = regularFileDataSource(url: jsonlURL, kind: .jsonl, allowsEmpty: true) {
                return jsonlSource
            }
        }

        throw BeadError.projectMissingDataSource(projectURL)
    }

    private func sqliteDataSourceIfPopulated(_ url: URL) -> BeadsDataSource? {
        guard let source = regularFileDataSource(url: url, kind: .sqlite),
              sqliteContainsVisibleIssues(at: url) else {
            return nil
        }
        return source
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

    private func sqliteContainsVisibleIssues(at url: URL) -> Bool {
        guard let database = try? SQLiteDatabase.open(url: url) else { return false }
        defer { sqlite3_close(database) }

        SQLiteDatabase.applyReadPragmas(database)
        guard SQLiteDatabase.tableExists("issues", in: database) else { return false }
        let whereClause = SQLiteDatabase.columnExists("deleted_at", in: "issues", database: database)
            ? " WHERE deleted_at IS NULL"
            : ""
        let sql = "SELECT 1 FROM issues\(whereClause) LIMIT 1"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
