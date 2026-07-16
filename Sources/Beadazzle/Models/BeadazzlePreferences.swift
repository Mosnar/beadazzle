import Foundation

enum BeadazzlePreferenceKeys {
    static let bdCLIPath = "BDCLIPath"
    static let receivesBetaUpdates = "ReceivesBetaUpdates"
    static let legacyStaleCutoffDays = "StaleCutoffDays"
    static let legacyShowsOwnerInBeadList = "ShowsOwnerInBeadList"
    static let legacyShowsAssigneeInBeadList = "ShowsAssigneeInBeadList"
    static let legacyShowsDueDateInBeadList = "ShowsDueDateInBeadList"
    static let legacyShowsCommentsInBeadList = "ShowsCommentsInBeadList"

    static func staleCutoffDays(projectURL: URL) -> String {
        "StaleCutoffDays.\(projectURL.standardizedFileURL.path)"
    }

    static func showsOwnerInBeadList(projectURL: URL) -> String {
        "ViewOptions.ShowsOwnerInBeadList.\(projectURL.standardizedFileURL.path)"
    }

    static func showsAssigneeInBeadList(projectURL: URL) -> String {
        "ViewOptions.ShowsAssigneeInBeadList.\(projectURL.standardizedFileURL.path)"
    }

    static func showsDueDateInBeadList(projectURL: URL) -> String {
        "ViewOptions.ShowsDueDateInBeadList.\(projectURL.standardizedFileURL.path)"
    }

    static func showsCommentsInBeadList(projectURL: URL) -> String {
        "ViewOptions.ShowsCommentsInBeadList.\(projectURL.standardizedFileURL.path)"
    }

    static func hiddenTypes(projectURL: URL) -> String {
        "HiddenTypes.\(projectURL.standardizedFileURL.path)"
    }

    static func hiddenStatuses(projectURL: URL) -> String {
        "HiddenStatuses.\(projectURL.standardizedFileURL.path)"
    }

    static func hidesParentsWithOnlyBlockedChildrenInReady(projectURL: URL) -> String {
        "HidesParentsWithOnlyBlockedChildrenInReady.\(projectURL.standardizedFileURL.path)"
    }

    static func automaticallyRefreshesExternalChanges(projectURL: URL) -> String {
        "AutomaticallyRefreshExternalChanges.\(projectURL.standardizedFileURL.path)"
    }

    static func savedViews(projectURL: URL) -> String {
        "SavedViews.\(projectURL.standardizedFileURL.path)"
    }

    static func workspaceState(projectURL: URL) -> String {
        "WorkspaceState.\(projectURL.standardizedFileURL.path)"
    }
}

struct BeadListDisplayOptions: Equatable, Sendable {
    var showsOwner = false
    var showsAssignee = false
    var showsDueDate = false
    var showsComments = true

    static let compact = BeadListDisplayOptions()
}

enum BeadazzleOptionScope: String, CaseIterable, Sendable {
    case appPreference
    case projectConfiguration
    case projectViewOption
}

struct BeadazzleOptionInventoryEntry: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let scope: BeadazzleOptionScope
    let persistence: String
    let defaultValue: String
    let uiLocation: String
    let behavior: String
}

enum BeadazzleOptionInventory {
    static let entries: [BeadazzleOptionInventoryEntry] = [
        BeadazzleOptionInventoryEntry(
            id: "bdCLIPath",
            title: "bd CLI path",
            scope: .appPreference,
            persistence: BeadazzlePreferenceKeys.bdCLIPath,
            defaultValue: "Automatic",
            uiLocation: "Settings > General",
            behavior: "Chooses the bd executable used by the app."
        ),
        BeadazzleOptionInventoryEntry(
            id: "automaticallyChecksForUpdates",
            title: "Automatically check for updates",
            scope: .appPreference,
            persistence: "Sparkle updater preferences",
            defaultValue: "Sparkle default",
            uiLocation: "Settings > Updates",
            behavior: "Controls automatic Sparkle update checks."
        ),
        BeadazzleOptionInventoryEntry(
            id: "receivesBetaUpdates",
            title: "Receive beta updates",
            scope: .appPreference,
            persistence: BeadazzlePreferenceKeys.receivesBetaUpdates,
            defaultValue: "Off",
            uiLocation: "Settings > Updates",
            behavior: "Includes beta channels in the appcast request."
        ),
        BeadazzleOptionInventoryEntry(
            id: "staleCutoffDays",
            title: "Stale cut-off",
            scope: .projectConfiguration,
            persistence: "StaleCutoffDays.<project path>",
            defaultValue: "\(BeadProjectIndex.defaultStaleCutoffDays) days",
            uiLocation: "Project Settings > Workflow",
            behavior: "Changes stale bead classification for the active project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "hidesParentsWithOnlyBlockedChildrenInReady",
            title: "Hide blocked-only ready parents",
            scope: .projectConfiguration,
            persistence: "HidesParentsWithOnlyBlockedChildrenInReady.<project path>",
            defaultValue: "On",
            uiLocation: "Project Settings > Workflow",
            behavior: "Changes ready-list roll-up behavior for the active project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "automaticallyRefreshesExternalChanges",
            title: "Automatically refresh external changes",
            scope: .projectConfiguration,
            persistence: "AutomaticallyRefreshExternalChanges.<project path>",
            defaultValue: "On",
            uiLocation: "Project Settings > Storage",
            behavior: "Exports and reloads marker-only external Beads changes without polling."
        ),
        BeadazzleOptionInventoryEntry(
            id: "hiddenTypes",
            title: "Hidden issue types",
            scope: .projectConfiguration,
            persistence: "HiddenTypes.<project path>",
            defaultValue: "None",
            uiLocation: "Project Settings > Types",
            behavior: "Hides project issue types from new choices while preserving existing values."
        ),
        BeadazzleOptionInventoryEntry(
            id: "hiddenStatuses",
            title: "Hidden statuses",
            scope: .projectConfiguration,
            persistence: "HiddenStatuses.<project path>",
            defaultValue: "None",
            uiLocation: "Project Settings > Statuses",
            behavior: "Hides project statuses from new choices while preserving existing values."
        ),
        BeadazzleOptionInventoryEntry(
            id: "showsOwnerInBeadList",
            title: "Show owner",
            scope: .projectViewOption,
            persistence: "ViewOptions.ShowsOwnerInBeadList.<project path>",
            defaultValue: "Off",
            uiLocation: "Issue List > View Options",
            behavior: "Shows owner metadata in issue rows for the active project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "showsAssigneeInBeadList",
            title: "Show assignee",
            scope: .projectViewOption,
            persistence: "ViewOptions.ShowsAssigneeInBeadList.<project path>",
            defaultValue: "Off",
            uiLocation: "Issue List > View Options",
            behavior: "Shows assignee metadata in issue rows for the active project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "showsDueDateInBeadList",
            title: "Show due date",
            scope: .projectViewOption,
            persistence: "ViewOptions.ShowsDueDateInBeadList.<project path>",
            defaultValue: "Off",
            uiLocation: "Issue List > View Options",
            behavior: "Shows due date metadata in issue rows for the active project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "showsCommentsInBeadList",
            title: "Show comments",
            scope: .projectViewOption,
            persistence: "ViewOptions.ShowsCommentsInBeadList.<project path>",
            defaultValue: "On",
            uiLocation: "Issue List > View Options",
            behavior: "Shows comment counts in issue rows for the active project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "savedViews",
            title: "Sidebar bookmarks",
            scope: .projectViewOption,
            persistence: "SavedViews.<project path>",
            defaultValue: "None",
            uiLocation: "Sidebar > Bookmarks",
            behavior: "Stores private per-project filter and sort bookmarks on this Mac."
        ),
        BeadazzleOptionInventoryEntry(
            id: "workspaceState",
            title: "Saved workspace state",
            scope: .projectViewOption,
            persistence: "WorkspaceState.<project path>",
            defaultValue: "None",
            uiLocation: "Project Settings > Storage",
            behavior: "Remembers the last view, filters, sort, selection, and expansion for this project on this Mac."
        )
    ]
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
