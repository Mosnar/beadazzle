import Foundation

/// The effective Beads runtime selected by `bd context` for an opened project.
///
/// This is resolved once when a project opens and reused by routine reloads so list
/// navigation and post-mutation reconciliation never spawn capability probes. The
/// environment also prevents Beadazzle from reading `<project>/.beads` while `bd`
/// writes through a worktree redirect or an explicitly configured Beads directory.
struct BeadsProjectEnvironment: Equatable, Sendable {
    enum StorageMode: Equatable, Sendable {
        case embedded
        case server
        case sharedServer

        var displayName: String {
            switch self {
            case .embedded:
                "Embedded Dolt"
            case .server:
                "Dolt Server"
            case .sharedServer:
                "Shared Dolt Server"
            }
        }

        var refreshesWhenAppActivates: Bool {
            self != .embedded
        }
    }

    enum GitIntegration: Equatable, Sendable {
        case unknown
        case enabled
        case disabled

        var displayName: String {
            switch self {
            case .unknown:
                "Git integration unknown"
            case .enabled:
                "Git integration enabled"
            case .disabled:
                "Stealth"
            }
        }
    }

    enum Role: Equatable, Sendable {
        case maintainer
        case contributor
        case other(String)

        var displayName: String {
            switch self {
            case .maintainer:
                "Maintainer"
            case .contributor:
                "Contributor"
            case .other(let value):
                value
            }
        }
    }

    var context: BeadsProjectContext
    var projectURL: URL
    var beadsDirectoryURL: URL
    var storageMode: StorageMode
    var gitIntegration: GitIntegration
    var role: Role

    init(
        context: BeadsProjectContext,
        projectURL: URL,
        gitIntegration: GitIntegration = .unknown
    ) throws {
        let normalizedBackend = context.backend?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedBackend == "dolt" else {
            throw BeadError.unsupportedProjectMode(
                projectURL,
                "The project reports the \(normalizedBackend?.nilIfBlank ?? "unknown") backend. Migrate it to current Dolt storage with bd, then check again."
            )
        }

        let normalizedMode = context.doltMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedMode {
        case "embedded":
            storageMode = .embedded
        case "server":
            storageMode = .server
        case "shared-server", "shared_server", "shared":
            storageMode = .sharedServer
        default:
            throw BeadError.unsupportedProjectMode(
                projectURL,
                "The project reports the \(normalizedMode?.nilIfBlank ?? "unknown") Dolt storage mode, which Beadazzle does not recognize."
            )
        }

        let rawDirectory = context.beadsDirectory?.nilIfBlank
        if let rawDirectory {
            let expandedDirectory = NSString(string: rawDirectory).expandingTildeInPath
            if NSString(string: expandedDirectory).isAbsolutePath {
                beadsDirectoryURL = URL(fileURLWithPath: expandedDirectory, isDirectory: true).standardizedFileURL
            } else {
                beadsDirectoryURL = projectURL
                    .appendingPathComponent(expandedDirectory, isDirectory: true)
                    .standardizedFileURL
            }
        } else {
            beadsDirectoryURL = projectURL
                .appendingPathComponent(".beads", isDirectory: true)
                .standardizedFileURL
        }

        let normalizedRole = context.role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedRole {
        case "maintainer", "team":
            role = .maintainer
        case "contributor":
            role = .contributor
        default:
            role = .other(context.role?.nilIfBlank ?? "Unknown role")
        }

        self.context = context
        self.projectURL = projectURL.standardizedFileURL
        self.gitIntegration = gitIntegration
    }

    var isRedirected: Bool {
        if context.isRedirected == true || context.isWorktree == true {
            return true
        }
        let localDirectory = projectURL
            .appendingPathComponent(".beads", isDirectory: true)
            .standardizedFileURL
        return beadsDirectoryURL.standardizedFileURL != localDirectory
    }

    func applying(storageConfig: ProjectStorageConfig) -> BeadsProjectEnvironment {
        var copy = self
        if storageConfig.noGitOperationsStatus.isUnavailable {
            copy.gitIntegration = .unknown
        } else {
            // An unset no-git-ops value uses bd's normal Git-integrated default.
            copy.gitIntegration = storageConfig.noGitOperations == true ? .disabled : .enabled
        }
        return copy
    }

}
