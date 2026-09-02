import Foundation

protocol BeadOwnerIdentityResolving: Sendable {
    func resolve(projectURL: URL) async -> BeadOwnerIdentity
}

/// Resolves the identity `bd` itself would use as the actor, so a bead created here is
/// attributed the same way `bd`, an agent, or another Beads client resolves it. From
/// `bd --help`: "Actor name for audit trail (default: $BEADS_ACTOR, git user.name, $USER)".
struct BeadOwnerIdentityResolver: BeadOwnerIdentityResolving {
    private static let gitLookupTimeout: TimeInterval = 2

    func resolve(projectURL: URL) async -> BeadOwnerIdentity {
        let executable = BeadsCLI.executable()
        let environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)
        // Why: only the step ahead of the git lookup may short-circuit it — $USER sits
        // behind `git user.name` in bd's chain and must not win by skipping the subprocess.
        if let actor = Self.beadsActorIdentity(environment: environment) {
            return actor
        }

        let gitUserName = await Task.detached(priority: .utility) {
            Self.readGitUserName(
                projectURL: projectURL,
                environment: environment,
                timeout: Self.gitLookupTimeout
            )
        }.value
        return Self.identity(environment: environment, gitUserName: gitUserName) ?? .unavailable
    }

    static func identity(
        environment: [String: String],
        gitUserName: String?
    ) -> BeadOwnerIdentity? {
        if let actor = beadsActorIdentity(environment: environment) {
            return actor
        }
        if let gitUserName = gitUserName?.nilIfBlank {
            return .resolved(value: gitUserName, source: .gitConfiguration)
        }
        if let user = environment["USER"]?.nilIfBlank {
            return .resolved(value: user, source: .processUser)
        }
        return nil
    }

    static func beadsActorIdentity(environment: [String: String]) -> BeadOwnerIdentity? {
        guard let actor = environment["BEADS_ACTOR"]?.nilIfBlank else { return nil }
        return .resolved(value: actor, source: .beadsActor)
    }

    static func readGitUserName(
        projectURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "config", "user.name"]
        process.currentDirectoryURL = projectURL
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfBlank
    }
}
