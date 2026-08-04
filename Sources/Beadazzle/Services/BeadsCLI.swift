import Foundation

enum BeadsCLI {
    /// Variables injected into Beadazzle itself by Xcode's debugger belong to the host
    /// process, not command-line helpers. Forwarding them loads Xcode instrumentation
    /// into `bd`, `dolt`, `git`, and `ssh`, which can make otherwise fast commands take
    /// dramatically longer and can change their dynamic-library resolution.
    private static let hostOnlyEnvironmentPrefixes = [
        "DYLD_",
        "__XCODE_",
        "__XPC_",
    ]

    private static let hostOnlyEnvironmentKeys: Set<String> = [
        "IDE_DISABLED_OS_ACTIVITY_DT_MODE",
        "OS_ACTIVITY_DT_MODE",
        "OS_ACTIVITY_TOOLS_OVERSIZE",
        "OS_ACTIVITY_TOOLS_PRIVACY",
        "SQLITE_ENABLE_THREAD_ASSERTIONS",
    ]

    static func executable() -> (url: URL, prefix: [String]) {
        executable(
            configuredPath: UserDefaults.standard.string(forKey: BeadazzlePreferenceKeys.bdCLIPath),
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    static func executable(
        configuredPath: String? = nil,
        environment: [String: String],
        homeDirectory: URL,
        isExecutable: (String) -> Bool
    ) -> (url: URL, prefix: [String]) {
        if let configuredPath = configuredPath?.nilIfBlank,
           isExecutable(configuredPath) {
            return (URL(fileURLWithPath: configuredPath), [])
        }

        if let override = environment["BEADAZZLE_BD_PATH"],
           isExecutable(override) {
            return (URL(fileURLWithPath: override), [])
        }

        for directory in pathDirectories(environment: environment, homeDirectory: homeDirectory) {
            let candidate = directory.appendingPathComponent("bd")
            if isExecutable(candidate.path) {
                return (candidate, [])
            }
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["bd"])
    }

    /// Environment for `bd` subprocesses. When the app is launched via LaunchServices
    /// (Finder/Dock) the inherited PATH is the minimal system one, so helpers `bd` itself
    /// shells out to (git, dolt, version-manager shims) would not resolve even though we
    /// found `bd`. Augment PATH with the same fallback directories used to locate `bd`
    /// and prefer the resolved executable's own directory so its companion tools use
    /// the same installation. `/usr/bin/env` is only a wrapper and does not establish
    /// a toolchain directory.
    static func subprocessEnvironment(executableURL: URL) -> [String: String] {
        subprocessEnvironment(
            base: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            executableURL: executableURL
        )
    }

    static func subprocessEnvironment(
        base: [String: String],
        homeDirectory: URL,
        executableURL: URL
    ) -> [String: String] {
        var directories = pathDirectories(environment: base, homeDirectory: homeDirectory)
        let executableDirectory = executableURL.deletingLastPathComponent()
        let isEnvWrapper = executableURL.standardizedFileURL.path == "/usr/bin/env"
        if !isEnvWrapper && executableDirectory.path != "/" {
            directories.removeAll { $0 == executableDirectory }
            directories.insert(executableDirectory, at: 0)
        }
        var environment = base
        for key in environment.keys where isHostOnlyEnvironmentKey(key) {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = directories.map(\.path).joined(separator: ":")
        return environment
    }

    private static func isHostOnlyEnvironmentKey(_ key: String) -> Bool {
        hostOnlyEnvironmentKeys.contains(key)
            || hostOnlyEnvironmentPrefixes.contains(where: key.hasPrefix)
    }

    private static func pathDirectories(environment: [String: String], homeDirectory: URL) -> [URL] {
        let path = environment["PATH"] ?? ""
        var directories = path
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) }

        let fallbackDirectories = [
            homeDirectory.appendingPathComponent(".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin")
        ]

        for url in fallbackDirectories {
            if !directories.contains(url) {
                directories.append(url)
            }
        }

        return directories
    }
}
