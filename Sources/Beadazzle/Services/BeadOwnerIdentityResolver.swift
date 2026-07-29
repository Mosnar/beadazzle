import Foundation

protocol BeadOwnerIdentityResolving: Sendable {
    func resolve(projectURL: URL) async -> BeadOwnerIdentity
}

struct BeadOwnerIdentityResolver: BeadOwnerIdentityResolving {
    private static let gitLookupTimeout: TimeInterval = 2

    func resolve(projectURL: URL) async -> BeadOwnerIdentity {
        let executable = BeadsCLI.executable()
        let environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)
        if let identity = Self.identity(environment: environment, gitEmail: nil) {
            return identity
        }

        let gitEmail = await Task.detached(priority: .utility) {
            Self.readGitEmail(
                projectURL: projectURL,
                environment: environment,
                timeout: Self.gitLookupTimeout
            )
        }.value
        return Self.identity(environment: environment, gitEmail: gitEmail) ?? .unavailable
    }

    static func identity(
        environment: [String: String],
        gitEmail: String?
    ) -> BeadOwnerIdentity? {
        if let authorEmail = environment["GIT_AUTHOR_EMAIL"], !authorEmail.isEmpty {
            return .resolved(value: authorEmail, source: .environment)
        }
        if let gitEmail = gitEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !gitEmail.isEmpty {
            return .resolved(value: gitEmail, source: .gitConfiguration)
        }
        return nil
    }

    static func readGitEmail(
        projectURL: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "config", "user.email"]
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
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }
}
