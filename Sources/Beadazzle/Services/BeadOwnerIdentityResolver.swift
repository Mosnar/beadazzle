import Foundation

protocol BeadOwnerIdentityResolving: Sendable {
    func resolve(projectURL: URL) async -> BeadOwnerIdentity
}

/// Resolves the identity `bd` records as the actor — the name it stamps on `created_by`,
/// comment authors, and events — so a bead assigned to "Me" carries the same name bd, an
/// agent, or another Beads client would write. bd's chain (`getActorWithGit` in
/// `cmd/bd/main.go`): `--actor`, `$BEADS_ACTOR`, `$BD_ACTOR`, the tracker's `config.yaml`
/// `actor` key, `git config user.name`, then `$USER`.
///
/// Deliberately not bd's `owner` field: bd fills that from the Git email for attribution,
/// while assignees are names, and the actor is the name a bead's history already shows.
struct BeadOwnerIdentityResolver: BeadOwnerIdentityResolving {
    /// Matches the command service's read-only `bd` ceiling; `config show` opens the database.
    private static let bdLookupTimeout: TimeInterval = 10
    private static let gitLookupTimeout: TimeInterval = 2

    func resolve(projectURL: URL) async -> BeadOwnerIdentity {
        let executable = BeadsCLI.executable()
        let environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)
        if let actor = Self.environmentActorIdentity(environment: environment) {
            return actor
        }

        // Why: each subprocess runs only when every step ahead of it came up empty — a
        // configured actor never pays for the git lookup, and $USER, which sits behind
        // `git user.name` in bd's chain, must not win by skipping it.
        let configuredActor = await Task.detached(priority: .utility) {
            Self.readConfiguredActor(
                projectURL: projectURL,
                executable: executable,
                environment: environment,
                timeout: Self.bdLookupTimeout
            )
        }.value
        var gitUserName: String?
        if configuredActor == nil {
            gitUserName = await Task.detached(priority: .utility) {
                Self.readGitUserName(
                    projectURL: projectURL,
                    environment: environment,
                    timeout: Self.gitLookupTimeout
                )
            }.value
        }
        return Self.identity(
            environment: environment,
            configuredActor: configuredActor,
            gitUserName: gitUserName
        ) ?? .unavailable
    }

    static func identity(
        environment: [String: String],
        configuredActor: String?,
        gitUserName: String?
    ) -> BeadOwnerIdentity? {
        if let actor = environmentActorIdentity(environment: environment) {
            return actor
        }
        if let configuredActor = configuredActor?.nilIfBlank {
            return .resolved(value: configuredActor, source: .configuredActor)
        }
        if let gitUserName = gitUserName?.nilIfBlank {
            return .resolved(value: gitUserName, source: .gitConfiguration)
        }
        if let user = environment["USER"]?.nilIfBlank {
            return .resolved(value: user, source: .processUser)
        }
        return nil
    }

    static func environmentActorIdentity(environment: [String: String]) -> BeadOwnerIdentity? {
        if let actor = environment["BEADS_ACTOR"]?.nilIfBlank {
            return .resolved(value: actor, source: .beadsActor)
        }
        if let actor = environment["BD_ACTOR"]?.nilIfBlank {
            return .resolved(value: actor, source: .legacyBeadsActor)
        }
        return nil
    }

    /// The tracker's configured actor, read through `bd config show --json`. `config get`
    /// is unusable here: it prints "actor (not set)" with a zero exit when the key is absent.
    static func readConfiguredActor(
        projectURL: URL,
        executable: (url: URL, prefix: [String]),
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        guard let output = readCommandOutput(
            executableURL: executable.url,
            arguments: executable.prefix + ["--readonly", "config", "show", "--json"],
            projectURL: projectURL,
            environment: environment,
            timeout: timeout
        ) else { return nil }
        return configuredActor(fromConfigShowOutput: output)
    }

    static func configuredActor(fromConfigShowOutput output: String) -> String? {
        let payload = BeadsJSONCommandOutput.payload(from: output)
        guard let entries = try? JSONDecoder().decode([ConfigEntry].self, from: Data(payload.utf8)) else {
            return nil
        }
        return entries.first { $0.key == "actor" }?.value?.nilIfBlank
    }

    static func readGitUserName(
        projectURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        readCommandOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "config", "user.name"],
            projectURL: projectURL,
            environment: environment,
            timeout: timeout
        )?.nilIfBlank
    }

    private struct ConfigEntry: Decodable {
        var key: String
        var value: String?
    }

    private static func readCommandOutput(
        executableURL: URL,
        arguments: [String],
        projectURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = projectURL
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

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
        return String(data: data, encoding: .utf8)
    }
}
