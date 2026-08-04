import Foundation

/// Makes OpenSSH's host-specific `IdentityAgent` choice available to tools that only
/// consult `SSH_AUTH_SOCK`. `ssh -G` performs the real OpenSSH config resolution, so
/// Host, Include, Match, token expansion, and vendor-specific socket paths keep working.
enum SSHAgentSocketResolver {
    struct Destination: Hashable, Sendable {
        var host: String
        var user: String?
        var port: Int?

        var configurationArguments: [String] {
            var arguments = ["-G"]
            if let user {
                arguments += ["-l", user]
            }
            if let port {
                arguments += ["-p", String(port)]
            }
            arguments.append(host)
            return arguments
        }
    }

    enum IdentityAgentSetting: Equatable, Sendable {
        case unspecified
        case disabled
        case environmentVariable(String)
        case path(String)
    }

    private actor ConfigurationCache {
        private var settingsByDestination: [Destination: IdentityAgentSetting] = [:]

        func setting(for destination: Destination) -> IdentityAgentSetting? {
            settingsByDestination[destination]
        }

        func store(_ setting: IdentityAgentSetting, for destination: Destination) {
            settingsByDestination[destination] = setting
        }
    }

    private static let configurationCache = ConfigurationCache()

    static func environment(
        base: [String: String],
        remoteURL: String,
        projectURL: URL
    ) async -> [String: String] {
        guard let destination = sshDestination(from: remoteURL) else { return base }
        if let cachedSetting = await configurationCache.setting(for: destination) {
            return applying(cachedSetting, to: base)
        }
        do {
            let result = try await CancellableProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: destination.configurationArguments,
                currentDirectoryURL: projectURL,
                environment: base,
                outputLimit: 64 * 1_024,
                timeout: .seconds(3)
            )
            guard result.terminationStatus == 0 else { return base }
            let setting = identityAgentSetting(from: result.output)
            await configurationCache.store(setting, for: destination)
            return applying(setting, to: base)
        } catch {
            return base
        }
    }

    static func sshDestination(from remoteURL: String) -> Destination? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.lowercased().hasPrefix("git+")
            ? String(trimmed.dropFirst(4))
            : trimmed

        if let components = URLComponents(string: normalized),
           components.scheme?.lowercased() == "ssh",
           let host = components.host?.nilIfBlank {
            return Destination(
                host: host,
                user: components.user?.nilIfBlank,
                port: components.port
            )
        }
        guard !normalized.contains("://"),
              let separator = normalized.firstIndex(of: ":"),
              separator != normalized.startIndex else {
            return nil
        }
        let destination = normalized[..<separator]
        let fields = destination.split(separator: "@", maxSplits: 1).map(String.init)
        let host = fields.last?.nilIfBlank
        guard let host else { return nil }
        return Destination(
            host: host,
            user: fields.count == 2 ? fields[0].nilIfBlank : nil,
            port: nil
        )
    }

    static func sshHost(from remoteURL: String) -> String? {
        sshDestination(from: remoteURL)?.host
    }

    static func identityAgentSetting(from sshConfiguration: String) -> IdentityAgentSetting {
        for line in sshConfiguration.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2,
                  fields[0].caseInsensitiveCompare("identityagent") == .orderedSame else {
                continue
            }
            let value = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.caseInsensitiveCompare("none") != .orderedSame else {
                return .disabled
            }
            guard let path = value.nilIfBlank else { return .unspecified }
            if path.caseInsensitiveCompare("SSH_AUTH_SOCK") == .orderedSame {
                return .unspecified
            }
            if path.hasPrefix("$"), path.count > 1 {
                return .environmentVariable(String(path.dropFirst()))
            }
            return .path(path)
        }
        return .unspecified
    }

    static func identityAgentPath(from sshConfiguration: String) -> String? {
        guard case .path(let path) = identityAgentSetting(from: sshConfiguration) else {
            return nil
        }
        return path
    }

    static func applying(
        _ setting: IdentityAgentSetting,
        to base: [String: String]
    ) -> [String: String] {
        var environment = base
        switch setting {
        case .unspecified:
            break
        case .disabled:
            environment.removeValue(forKey: "SSH_AUTH_SOCK")
        case .environmentVariable(let name):
            if let socketPath = base[name]?.nilIfBlank {
                environment["SSH_AUTH_SOCK"] = socketPath
            }
        case .path(let socketPath):
            environment["SSH_AUTH_SOCK"] = socketPath
        }
        return environment
    }
}
