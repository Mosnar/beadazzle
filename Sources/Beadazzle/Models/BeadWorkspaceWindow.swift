import Foundation

/// Identifies a workspace window and the project it was asked to show. This is the
/// `WindowGroup` presented value, so `openWindow(value:)` can create a second workspace
/// window and macOS window restoration can reopen the same projects.
///
/// The `id` is what makes each request distinct: `openWindow` reuses an existing window
/// when handed an equal value, and an explicit "open in new window" must always produce a
/// new one. Reusing an already-open project is decided in `BeadWorkspaceWindowRegistry`
/// instead, which can match a project even after a window switched to it from the inside —
/// something a value comparison can't see.
///
/// It identifies the *request*, not the window. SwiftUI can hand a live window a different
/// presented value — scene restoration swaps its own stored value in shortly after launch —
/// so `WorkspaceWindowRoot` keys its registry entry on a `@State` identity of its own and
/// treats this value purely as payload.
struct BeadWorkspaceWindowRequest: Hashable, Codable, Identifiable {
    var id: UUID
    var projectPath: String?
    /// True only for a request built in-process by an explicit "open in new window"
    /// action. Deliberately excluded from `CodingKeys`: a restored window must not
    /// inherit it, so restoration can fall back to the recents when the recorded folder
    /// vanished, while an explicit open of a missing folder surfaces the failure instead
    /// of silently showing an unrelated project.
    var opensProjectExplicitly = false
    /// Carries an in-process retry after a closed window's final snapshot export failed.
    /// Like `opensProjectExplicitly`, this is deliberately not restored across launches.
    var forcesSnapshotExport = false

    private enum CodingKeys: String, CodingKey {
        case id
        case projectPath
    }

    init(
        id: UUID = UUID(),
        projectURL: URL? = nil,
        opensProjectExplicitly: Bool = false,
        forcesSnapshotExport: Bool = false
    ) {
        self.id = id
        self.projectPath = projectURL?.standardizedFileURL.path
        self.opensProjectExplicitly = opensProjectExplicitly
        self.forcesSnapshotExport = forcesSnapshotExport
    }

    var projectURL: URL? {
        projectPath.map { URL(fileURLWithPath: $0) }
    }
}

/// Where a project should open. `.preferred` defers to the app preference; the other two
/// are explicit user commands and ignore it.
enum BeadProjectOpenDestination: Equatable, Sendable {
    case preferred
    case currentWindow
    case newWindow
}
