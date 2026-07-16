import Foundation

/// A single mutation/command failure, carrying enough structured detail for the
/// standardized error dialog: a short title, a human explanation, and — when the
/// failure came from a `bd` invocation — the exact command line and its output.
///
/// Beadazzle's users are technical and route every write through `bd`, so surfacing
/// the failing command and its output (rather than a flattened `localizedDescription`)
/// is a deliberate part of the unified feedback policy. `retry`, when present, re-runs
/// the originating mutation so the dialog can offer a "Try Again" affordance.
@MainActor
struct BeadMutationFailure: Identifiable {
    let id = UUID()
    /// Short, action-oriented headline, e.g. "Couldn't update assignee".
    var title: String
    /// Plain-language explanation of what went wrong.
    var message: String
    /// The `bd` command line that failed, if the failure originated from one.
    var command: String?
    /// The command's combined stdout/stderr, if available.
    var output: String?
    /// Re-runs the originating mutation. `nil` for non-retryable failures
    /// (validation guards, read-only bookmarks), which offer only a dismiss button.
    var retry: (() async -> Void)?

    var isRetryable: Bool { retry != nil }

    /// Structural equality ignoring `id`/`retry`, used to coalesce duplicate failures
    /// so a repeated failure doesn't stack multiple identical dialogs.
    func hasSameContent(as other: BeadMutationFailure) -> Bool {
        title == other.title
            && message == other.message
            && command == other.command
            && output == other.output
    }

    /// The dialog body: the explanation followed by the command and its output when
    /// present, each in its own labeled section so technical users can see exactly
    /// what ran and why it failed.
    var dialogMessage: String {
        var sections: [String] = []
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            sections.append(trimmedMessage)
        }
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Command:\n\(command)")
        }
        if let output {
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOutput.isEmpty {
                sections.append("Output:\n\(Self.truncated(trimmedOutput))")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    /// A concise single-line phrasing for VoiceOver announcements.
    var accessibilityAnnouncement: String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMessage.isEmpty ? title : "\(title). \(trimmedMessage)"
    }

    /// Alert message text can grow unbounded from a verbose `bd` failure; cap it so the
    /// dialog stays usable while still showing the leading, most-relevant output.
    private static let maxOutputLength = 2000
    private static func truncated(_ text: String) -> String {
        guard text.count > maxOutputLength else { return text }
        let prefix = text.prefix(maxOutputLength)
        return "\(prefix)\n… (output truncated)"
    }
}
