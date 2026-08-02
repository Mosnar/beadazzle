import Foundation

enum BeadazzlePreferenceKeys {
    static let bdCLIPath = "BDCLIPath"
    static let receivesBetaUpdates = "ReceivesBetaUpdates"
    static let defaultNewBeadAssigneeMode = "NewBeads.DefaultAssignee.Mode"
    static let defaultNewBeadAssigneeValue = "NewBeads.DefaultAssignee.Value"
    static let issueTextSectionVisibilityMode = "Editor.BeadContent.EmptySectionMode"
    static let issueTextSectionOrder = "Editor.BeadContent.SectionOrder"
    static let issueTextSectionSuggestions = "Editor.BeadContent.TypeSuggestions"
    static let remoteFreshnessRecordPrefix = "Sync.Dolt.RemoteFreshness"
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

    static func newBeadAssigneeOverrideMode(projectURL: URL) -> String {
        "NewBeads.DefaultAssignee.OverrideMode.\(projectURL.standardizedFileURL.path)"
    }

    static func newBeadAssigneeOverrideValue(projectURL: URL) -> String {
        "NewBeads.DefaultAssignee.OverrideValue.\(projectURL.standardizedFileURL.path)"
    }

    static func issueTextSectionVisibilityModeOverride(projectURL: URL) -> String {
        "Editor.BeadContent.EmptySectionMode.Override.\(projectURL.standardizedFileURL.path)"
    }

    static func issueTextSectionOrderOverride(projectURL: URL) -> String {
        "Editor.BeadContent.SectionOrder.Override.\(projectURL.standardizedFileURL.path)"
    }

    static func issueTextSectionSuggestionOverrides(projectURL: URL) -> String {
        "Editor.BeadContent.TypeSuggestions.Override.\(projectURL.standardizedFileURL.path)"
    }

    static func pinnedStateDimensions(projectURL: URL) -> String {
        "PinnedStateDimensions.\(projectURL.standardizedFileURL.path)"
    }

    static func stateDimensionDisplayNames(projectURL: URL) -> String {
        "StateDimensionDisplayNames.\(projectURL.standardizedFileURL.path)"
    }

    static func stateValueDisplayNames(projectURL: URL) -> String {
        "StateValueDisplayNames.\(projectURL.standardizedFileURL.path)"
    }

    static func archivedStateValues(projectURL: URL) -> String {
        "ArchivedStateValues.\(projectURL.standardizedFileURL.path)"
    }

    static func savedViews(projectURL: URL) -> String {
        "SavedViews.\(projectURL.standardizedFileURL.path)"
    }

    static func workspaceState(projectURL: URL) -> String {
        "WorkspaceState.\(projectURL.standardizedFileURL.path)"
    }

    static func semanticDefinitions(trackerDirectoryURL: URL) -> String {
        "SemanticDefinitions.Tracker.\(trackerDirectoryURL.standardizedFileURL.path)"
    }

    static func semanticDefinitionsTrackerRoute(projectURL: URL) -> String {
        "SemanticDefinitions.Route.\(projectURL.standardizedFileURL.path)"
    }

    static func legacySemanticDefinitions(projectURL: URL) -> String {
        "SemanticDefinitions.\(projectURL.standardizedFileURL.path)"
    }

    static func remoteFreshnessRecord(trackerIdentity: String) -> String {
        "\(remoteFreshnessRecordPrefix).\(ProjectDoltRemoteFreshnessRecord.fingerprint(trackerIdentity))"
    }

    static func beadsSetupIntent(projectURL: URL) -> String {
        "BeadsSetup.Intent.\(setupProjectFingerprint(projectURL))"
    }

    static func beadsSetupDismissedFingerprint(projectURL: URL) -> String {
        "BeadsSetup.Dismissed.\(setupProjectFingerprint(projectURL))"
    }

    private static func setupProjectFingerprint(_ projectURL: URL) -> String {
        StableFingerprint.sha256(projectURL.standardizedFileURL.path)
    }
}

struct BeadazzleBoolPreferenceDescriptor: Equatable, Sendable {
    let id: String
    let key: String
    let defaultValue: Bool

    var defaultValueDescription: String {
        defaultValue ? "On" : "Off"
    }
}

enum BeadazzleAppBoolPreferences {
    static let automaticallyChecksDoltRemotes = BeadazzleBoolPreferenceDescriptor(
        id: "automaticallyChecksDoltRemotes",
        key: "Sync.Dolt.AutomaticallyChecksRemoteChanges",
        defaultValue: true
    )
    static let showsBackNavigationButton = BeadazzleBoolPreferenceDescriptor(
        id: "showsBackNavigationButton",
        key: "Display.Navigation.ShowsBackButton",
        defaultValue: false
    )
    static let showsForwardNavigationButton = BeadazzleBoolPreferenceDescriptor(
        id: "showsForwardNavigationButton",
        key: "Display.Navigation.ShowsForwardButton",
        defaultValue: false
    )
    static let showsAllChildrenInOutline = BeadazzleBoolPreferenceDescriptor(
        id: "showsAllChildrenInOutline",
        key: "Display.BeadList.ShowsAllChildrenInOutline",
        defaultValue: true
    )
    static let opensSplitViewOnSingleClick = BeadazzleBoolPreferenceDescriptor(
        id: "opensSplitViewOnSingleClick",
        key: "Display.BeadList.OpensSplitViewOnSingleClick",
        defaultValue: true
    )
    static let showsBeadIDUnderTitle = BeadazzleBoolPreferenceDescriptor(
        id: "showsBeadIDUnderTitle",
        key: "Display.BeadDetail.ShowsBeadIDUnderTitle",
        defaultValue: true
    )
    static let showsCopyBeadIDButtonInBreadcrumbs = BeadazzleBoolPreferenceDescriptor(
        id: "showsCopyBeadIDButtonInBreadcrumbs",
        key: "Display.BeadDetail.ShowsCopyBeadIDButtonInBreadcrumbs",
        defaultValue: true
    )
    static let showsProjectNameInBreadcrumbs = BeadazzleBoolPreferenceDescriptor(
        id: "showsProjectNameInBreadcrumbs",
        key: "Display.BeadDetail.ShowsProjectNameInBreadcrumbs",
        defaultValue: true
    )
    static let showsClosedBeadsInSidebar = BeadazzleBoolPreferenceDescriptor(
        id: "showsClosedBeadsInSidebar",
        key: "Display.Sidebar.ShowsClosedBeads",
        defaultValue: true
    )
    static let showsGatesInSidebar = BeadazzleBoolPreferenceDescriptor(
        id: "showsGatesInSidebar",
        key: "Display.Sidebar.ShowsGates",
        defaultValue: true
    )
    static let showsZeroCountSidebarSections = BeadazzleBoolPreferenceDescriptor(
        id: "showsZeroCountSidebarSections",
        key: "Display.Sidebar.ShowsZeroCountSections",
        defaultValue: true
    )

    static let all: [BeadazzleBoolPreferenceDescriptor] = [
        automaticallyChecksDoltRemotes,
        showsBackNavigationButton,
        showsForwardNavigationButton,
        showsAllChildrenInOutline,
        opensSplitViewOnSingleClick,
        showsBeadIDUnderTitle,
        showsCopyBeadIDButtonInBreadcrumbs,
        showsProjectNameInBreadcrumbs,
        showsClosedBeadsInSidebar,
        showsGatesInSidebar,
        showsZeroCountSidebarSections
    ]
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
            id: BeadazzleAppBoolPreferences.automaticallyChecksDoltRemotes.id,
            title: "Automatically check Dolt remotes for changes",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.automaticallyChecksDoltRemotes.key,
            defaultValue: BeadazzleAppBoolPreferences.automaticallyChecksDoltRemotes.defaultValueDescription,
            uiLocation: "Settings > General",
            behavior: "Periodically checks the lightweight Dolt data ref for Git-backed remotes while Beadazzle is active, without pulling."
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
            id: "defaultNewBeadAssignee",
            title: "Default assignee for new beads",
            scope: .appPreference,
            persistence: [
                BeadazzlePreferenceKeys.defaultNewBeadAssigneeMode,
                BeadazzlePreferenceKeys.defaultNewBeadAssigneeValue
            ].joined(separator: " + "),
            defaultValue: "Unassigned",
            uiLocation: "Settings > General",
            behavior: "Seeds the assignee on new bead drafts unless the active project overrides it."
        ),
        BeadazzleOptionInventoryEntry(
            id: "issueTextSectionVisibilityMode",
            title: "Empty bead sections",
            scope: .appPreference,
            persistence: BeadazzlePreferenceKeys.issueTextSectionVisibilityMode,
            defaultValue: IssueTextSectionVisibilityMode.suggestedForType.title,
            uiLocation: "Settings > Editor",
            behavior: "Chooses which empty built-in text sections appear initially."
        ),
        BeadazzleOptionInventoryEntry(
            id: "issueTextSectionSuggestions",
            title: "Suggested sections by type",
            scope: .appPreference,
            persistence: BeadazzlePreferenceKeys.issueTextSectionSuggestions,
            defaultValue: "Beads suggestions",
            uiLocation: "Settings > Editor",
            behavior: "Maps bead types to the empty text sections shown initially."
        ),
        BeadazzleOptionInventoryEntry(
            id: "issueTextSectionOrder",
            title: "Bead section order",
            scope: .appPreference,
            persistence: BeadazzlePreferenceKeys.issueTextSectionOrder,
            defaultValue: "Description, Acceptance Criteria, Design, Notes",
            uiLocation: "Settings > Editor",
            behavior: "Orders built-in text sections in editors and Find navigation."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsBackNavigationButton.id,
            title: "Show Back button",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsBackNavigationButton.key,
            defaultValue: BeadazzleAppBoolPreferences.showsBackNavigationButton.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the Back button in the workspace toolbar."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsForwardNavigationButton.id,
            title: "Show Forward button",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsForwardNavigationButton.key,
            defaultValue: BeadazzleAppBoolPreferences.showsForwardNavigationButton.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the Forward button in the workspace toolbar."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsAllChildrenInOutline.id,
            title: "Show all children in filtered outlines",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsAllChildrenInOutline.key,
            defaultValue: BeadazzleAppBoolPreferences.showsAllChildrenInOutline.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows expanded child beads as context even when they do not match the current filter."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.opensSplitViewOnSingleClick.id,
            title: "Open split view on single click",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.opensSplitViewOnSingleClick.key,
            defaultValue: BeadazzleAppBoolPreferences.opensSplitViewOnSingleClick.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Opens the split detail pane when a single bead is selected."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsBeadIDUnderTitle.id,
            title: "Show bead ID under title",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsBeadIDUnderTitle.key,
            defaultValue: BeadazzleAppBoolPreferences.showsBeadIDUnderTitle.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the selected bead's ID beneath its editable title."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsCopyBeadIDButtonInBreadcrumbs.id,
            title: "Show Copy Bead ID button in breadcrumbs",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsCopyBeadIDButtonInBreadcrumbs.key,
            defaultValue: BeadazzleAppBoolPreferences.showsCopyBeadIDButtonInBreadcrumbs.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the dedicated Copy Bead ID action in bead breadcrumbs."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsProjectNameInBreadcrumbs.id,
            title: "Show project name in breadcrumbs",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsProjectNameInBreadcrumbs.key,
            defaultValue: BeadazzleAppBoolPreferences.showsProjectNameInBreadcrumbs.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the project crumb on bead and gate detail screens."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsClosedBeadsInSidebar.id,
            title: "Show closed beads",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsClosedBeadsInSidebar.key,
            defaultValue: BeadazzleAppBoolPreferences.showsClosedBeadsInSidebar.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the Closed preset in the sidebar."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsGatesInSidebar.id,
            title: "Show gates",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsGatesInSidebar.key,
            defaultValue: BeadazzleAppBoolPreferences.showsGatesInSidebar.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Shows the Gates preset in the sidebar."
        ),
        BeadazzleOptionInventoryEntry(
            id: BeadazzleAppBoolPreferences.showsZeroCountSidebarSections.id,
            title: "Show sections with zero beads",
            scope: .appPreference,
            persistence: BeadazzleAppBoolPreferences.showsZeroCountSidebarSections.key,
            defaultValue: BeadazzleAppBoolPreferences.showsZeroCountSidebarSections.defaultValueDescription,
            uiLocation: "Settings > Display",
            behavior: "Keeps empty preset sections visible in the sidebar."
        ),
        BeadazzleOptionInventoryEntry(
            id: "projectNewBeadAssigneeOverride",
            title: "Project default assignee override",
            scope: .projectConfiguration,
            persistence: [
                "NewBeads.DefaultAssignee.OverrideMode.<project path>",
                "NewBeads.DefaultAssignee.OverrideValue.<project path>"
            ].joined(separator: " + "),
            defaultValue: "Use App Default",
            uiLocation: "Project Settings > Behavior",
            behavior: "Overrides the app default when starting new bead drafts for one project."
        ),
        BeadazzleOptionInventoryEntry(
            id: "projectIssueTextSectionOverrides",
            title: "Project bead section overrides",
            scope: .projectViewOption,
            persistence: "Editor.BeadContent.*.Override.<project path>",
            defaultValue: "Use App Default",
            uiLocation: "Project Settings > Content",
            behavior: "Privately overrides visibility, type suggestions, and order for one project on this Mac."
        ),
        BeadazzleOptionInventoryEntry(
            id: "create.require-description",
            title: "Require a description",
            scope: .projectConfiguration,
            persistence: "bd config create.require-description",
            defaultValue: "Off",
            uiLocation: "Project Settings > Content",
            behavior: "Shared Beads validation rule requiring descriptions on created beads."
        ),
        BeadazzleOptionInventoryEntry(
            id: "validation.on-create",
            title: "Creation validation behavior",
            scope: .projectConfiguration,
            persistence: "bd config validation.on-create",
            defaultValue: "None",
            uiLocation: "Project Settings > Content",
            behavior: "Chooses whether shared creation validation is ignored, warned, or enforced."
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
            id: "pinnedStateDimensions",
            title: "Pinned state properties",
            scope: .projectViewOption,
            persistence: "PinnedStateDimensions.<project path>",
            defaultValue: "None",
            uiLocation: "Project Settings > Properties",
            behavior: "Shows chosen bd state dimensions as ordered editable property rows in the inspector."
        ),
        BeadazzleOptionInventoryEntry(
            id: "stateDimensionDisplayNames",
            title: "State property display names",
            scope: .projectViewOption,
            persistence: "StateDimensionDisplayNames.<project path>",
            defaultValue: "Derived from the state identifier",
            uiLocation: "Project Settings > Properties",
            behavior: "Customizes how state dimensions appear without renaming their event-backed bd identifiers."
        ),
        BeadazzleOptionInventoryEntry(
            id: "stateValueDisplayNames",
            title: "State value display names",
            scope: .projectViewOption,
            persistence: "StateValueDisplayNames.<project path>",
            defaultValue: "The recorded state value",
            uiLocation: "Project Settings > Properties",
            behavior: "Customizes how state values appear without changing their labels or Activity history."
        ),
        BeadazzleOptionInventoryEntry(
            id: "archivedStateValues",
            title: "Archived state values",
            scope: .projectViewOption,
            persistence: "ArchivedStateValues.<project path>",
            defaultValue: "None",
            uiLocation: "Project Settings > Properties",
            behavior: "Keeps retired values out of new choices while preserving existing labels and Activity history."
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
