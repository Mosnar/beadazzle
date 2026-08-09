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
struct BeadWorkspaceWindowRequest: Hashable, Codable, Identifiable {
    var id: UUID
    var projectPath: String?

    init(id: UUID = UUID(), projectURL: URL? = nil) {
        self.id = id
        self.projectPath = projectURL?.standardizedFileURL.path
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
