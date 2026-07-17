import Foundation

enum BeadError: LocalizedError {
    case projectMissingDataSource(URL)
    case unsupportedProjectMode(URL, String)
    case invalidSnapshot(path: String, line: Int, message: String)
    case commandFailed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .projectMissingDataSource(let url):
            return "No readable current Beads snapshot found for \(url.path). Expected `issues.jsonl` in the tracker directory reported by `bd context`."
        case .unsupportedProjectMode(let url, let detail):
            return "Unsupported Beads project at \(url.path). \(detail)"
        case .invalidSnapshot(let path, let line, let message):
            return "Could not read Beads snapshot \(path) at line \(line): \(message)"
        case .commandFailed(let command, let output):
            return "`\(command)` failed: \(output)"
        }
    }
}
