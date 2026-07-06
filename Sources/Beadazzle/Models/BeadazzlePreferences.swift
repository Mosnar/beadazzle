import Foundation

enum BeadazzlePreferenceKeys {
    static let bdCLIPath = "BDCLIPath"
    static let staleCutoffDays = "StaleCutoffDays"
    static let showsOwnerInBeadList = "ShowsOwnerInBeadList"
    static let showsAssigneeInBeadList = "ShowsAssigneeInBeadList"
    static let showsDueDateInBeadList = "ShowsDueDateInBeadList"
    static let showsCommentsInBeadList = "ShowsCommentsInBeadList"

    static func hiddenTypes(projectURL: URL) -> String {
        "HiddenTypes.\(projectURL.standardizedFileURL.path)"
    }

    static func hiddenStatuses(projectURL: URL) -> String {
        "HiddenStatuses.\(projectURL.standardizedFileURL.path)"
    }
}

struct BeadListDisplayOptions: Equatable, Sendable {
    var showsOwner = false
    var showsAssignee = false
    var showsDueDate = false
    var showsComments = true

    static let compact = BeadListDisplayOptions()
}

enum WorkflowValueValidator {
    private static let pattern = #"^[a-z0-9][a-z0-9_-]*$"#

    static func normalizedIdentifier(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            throw BeadError.commandFailed(command: "bd config", output: "Name is required.")
        }
        guard normalized.range(of: pattern, options: .regularExpression) != nil else {
            throw BeadError.commandFailed(
                command: "bd config",
                output: "Use lowercase letters, numbers, underscores, and hyphens. Names must start with a letter or number."
            )
        }
        return normalized
    }
}
