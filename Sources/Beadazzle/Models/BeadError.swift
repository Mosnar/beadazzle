import Foundation

enum BeadError: LocalizedError {
    case projectMissingDataSource(URL)
    case sqliteOpen(String)
    case sqlitePrepare(String)
    case sqliteStep(String)
    case invalidSnapshot(path: String, line: Int, message: String)
    case commandFailed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .projectMissingDataSource(let url):
            return "No readable Beads snapshot found in \(url.path). Expected `.beads/issues.jsonl`, `.beads/beads.jsonl`, `.beads/beads.base.jsonl`, or a populated legacy `.beads/beads.db`."
        case .sqliteOpen(let message):
            return "Could not open Beads database: \(message)"
        case .sqlitePrepare(let message):
            return "Could not prepare database query: \(message)"
        case .sqliteStep(let message):
            return "Database query failed: \(message)"
        case .invalidSnapshot(let path, let line, let message):
            return "Could not read Beads snapshot \(path) at line \(line): \(message)"
        case .commandFailed(let command, let output):
            return "`\(command)` failed: \(output)"
        }
    }
}
