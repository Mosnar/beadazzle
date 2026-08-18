import Foundation

enum BeadError: LocalizedError {
    case projectMissingDataSource(URL)
    case unsupportedProjectMode(URL, String)
    case invalidSnapshot(path: String, line: Int, message: String)
    case commandFailed(command: String, output: String)
    /// The tracker and installed `bd` disagree about schema compatibility. Direction is
    /// carried in `BeadsSchemaSkew`; only database-behind skew is a migration.
    case trackerSchemaIncompatible(BeadsSchemaSkew?)
    /// The create subprocess exited successfully, but Beadazzle could not recover the
    /// server-authored ID. The write may already be durable, so repeating it is unsafe.
    case createOutcomeUncertain(command: String, output: String)

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
        case .trackerSchemaIncompatible(let skew):
            let base = skew?.resolution.errorDescription
                ?? BeadsSchemaSkewResolution.manualRecovery.errorDescription
            guard let summary = skew?.versionSummary else { return base }
            return "\(base) \(summary)"
        case .createOutcomeUncertain(let command, let output):
            return "`\(command)` may have created a bead, but Beadazzle could not confirm its ID: \(output)"
        }
    }

    /// The `bd` schema incompatibility this failure was caused by, if any.
    ///
    /// `bd` reports the mismatch in the failing command's output rather than through a
    /// distinct exit code, so the text is the only thing there is to classify.
    var schemaSkew: BeadsSchemaSkew? {
        switch self {
        case .commandFailed(_, let output), .createOutcomeUncertain(_, let output):
            return BeadsSchemaSkew.detect(in: output)
        case .invalidSnapshot(_, _, let message):
            return BeadsSchemaSkew.detect(in: message)
        case .trackerSchemaIncompatible(let skew):
            return skew
        case .projectMissingDataSource, .unsupportedProjectMode:
            return nil
        }
    }
}

extension BeadsSchemaSkew {
    /// Classifies any error thrown by the `bd` seams, including errors that are not
    /// `BeadError` (a decoding failure on skew-contaminated output, for example).
    static func detect(in error: Error) -> BeadsSchemaSkew? {
        if let beadError = error as? BeadError {
            return beadError.schemaSkew
        }
        return detect(in: error.localizedDescription)
    }
}
