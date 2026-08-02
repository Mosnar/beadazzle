import Foundation

enum DoltRemoteGenerationProbeError: LocalizedError, Equatable, Sendable {
    case unsupportedRemote
    case missingDoltReference
    case gitUnavailable
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRemote:
            "This remote does not use a Git URL that Beadazzle can check."
        case .missingDoltReference:
            "The remote does not advertise Dolt data."
        case .gitUnavailable:
            "Git is unavailable on this Mac."
        case .timedOut:
            "The remote did not respond in time."
        case .failed(let message):
            message.nilIfBlank ?? "The remote could not be checked."
        }
    }
}

/// Reads only the Git ref that contains a Git-backed Dolt remote's data. This never
/// fetches database objects and never touches Beads' embedded Dolt working directory.
enum GitDoltRemoteGenerationProbe {
    static func generation(
        remote: BeadsDoltRemote,
        projectURL: URL,
        timeout: TimeInterval = 10
    ) async throws -> String {
        guard let gitRemoteURL = normalizedGitRemoteURL(remote.url) else {
            throw DoltRemoteGenerationProbeError.unsupportedRemote
        }
        let output = try await runGitLSRemote(
            remoteURL: gitRemoteURL,
            projectURL: projectURL,
            timeout: timeout
        )
        return try generation(from: output)
    }

    static func normalizedGitRemoteURL(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let normalized = value.lowercased().hasPrefix("git+")
            ? String(value.dropFirst(4))
            : value
        if let scheme = URLComponents(string: normalized)?.scheme?.lowercased(),
           ["ssh", "http", "https", "git", "file"].contains(scheme) {
            return normalized
        }
        // Do not reinterpret an unsupported URL scheme's colon as an SCP separator.
        if normalized.contains("://") {
            return nil
        }

        if normalized.hasPrefix("/")
            || normalized.hasPrefix("./")
            || normalized.hasPrefix("../") {
            return normalized
        }

        // Git also accepts bare relative filesystem paths.
        if !normalized.contains(":"),
           normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return normalized
        }

        // Git also accepts SCP-style SSH paths with an optional user.
        let scpStyle = #"^(?:[^/@\s]+@)?[^/:\s]+:.+$"#
        if normalized.range(of: scpStyle, options: .regularExpression) != nil {
            return normalized
        }
        return nil
    }

    static func generation(from output: String) throws -> String {
        guard let line = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { $0.contains("refs/dolt/data") }),
              let candidate = line.split(whereSeparator: \Character.isWhitespace).first
        else {
            throw DoltRemoteGenerationProbeError.missingDoltReference
        }

        let generation = String(candidate).lowercased()
        let validLengths = [40, 64]
        let hexadecimalCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        guard validLengths.contains(generation.count),
              generation.unicodeScalars.allSatisfy(hexadecimalCharacters.contains)
        else {
            throw DoltRemoteGenerationProbeError.failed("The remote returned an invalid Dolt data reference.")
        }
        return generation
    }

    private static func runGitLSRemote(
        remoteURL: String,
        projectURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        try await runCancellableGitLSRemote(
            remoteURL: remoteURL,
            projectURL: projectURL,
            timeout: timeout
        )
    }

    private static func runCancellableGitLSRemote(
        remoteURL: String,
        projectURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        var environment = BeadsCLI.subprocessEnvironment(
            executableURL: URL(fileURLWithPath: "/usr/bin/env")
        )
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes"
        }
        do {
            let result = try await CancellableProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["git", "ls-remote", remoteURL, "refs/dolt/data"],
                currentDirectoryURL: projectURL,
                environment: environment,
                outputLimit: 64 * 1024,
                timeout: .seconds(timeout)
            )
            guard result.terminationStatus == 0 else {
                if result.terminationStatus == 127 {
                    throw DoltRemoteGenerationProbeError.gitUnavailable
                }
                // Git may echo credential-bearing remote URLs. Keep automatic-check
                // diagnostics intentionally generic rather than surfacing its stderr.
                throw DoltRemoteGenerationProbeError.failed(
                    "Git could not contact the Dolt remote."
                )
            }
            return result.output
        } catch is CancellationError {
            throw CancellationError()
        } catch CancellableProcessRunnerError.timedOut {
            throw DoltRemoteGenerationProbeError.timedOut
        } catch let error as DoltRemoteGenerationProbeError {
            throw error
        } catch {
            throw DoltRemoteGenerationProbeError.failed(
                "The remote check could not be started."
            )
        }
    }
}
