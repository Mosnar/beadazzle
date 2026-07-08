import Foundation

enum ProjectHealthAction: Equatable, Sendable {
    case exportingSnapshot
    case installingHooks
    case syncingBackup

    var title: String {
        switch self {
        case .exportingSnapshot:
            "Exporting snapshot"
        case .installingHooks:
            "Installing hooks"
        case .syncingBackup:
            "Syncing backup"
        }
    }
}

struct ProjectHealthSnapshot: Equatable, Sendable {
    var loadedAt: Date
    var context: ProjectHealthValue<BeadsProjectContext>
    var storageConfig: ProjectHealthValue<ProjectStorageConfig>
    var hooks: ProjectHealthValue<BeadsHooksStatus>
    var backup: ProjectHealthValue<BeadsBackupStatus>
    var snapshotFile: ProjectSnapshotFileStatus

    static func load(
        projectURL: URL,
        activeDataSource: BeadsDataSource?,
        commands: any BeadsCommanding
    ) async -> ProjectHealthSnapshot {
        let snapshotFile = ProjectSnapshotFileStatus.load(
            projectURL: projectURL,
            activeDataSource: activeDataSource
        )

        async let context = ProjectHealthValue.capture {
            try await commands.loadProjectContext(projectURL: projectURL)
        }
        async let storageConfig = ProjectHealthValue.capture {
            try await commands.loadProjectStorageConfig(projectURL: projectURL)
        }
        async let hooks = ProjectHealthValue.capture {
            try await commands.loadHooksStatus(projectURL: projectURL)
        }
        async let backup = ProjectHealthValue.capture {
            try await commands.loadBackupStatus(projectURL: projectURL)
        }

        return ProjectHealthSnapshot(
            loadedAt: Date(),
            context: await context,
            storageConfig: await storageConfig,
            hooks: await hooks,
            backup: await backup,
            snapshotFile: snapshotFile
        )
    }
}

struct ProjectHealthValue<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value?
    var errorMessage: String?

    var isAvailable: Bool {
        value != nil
    }

    static func available(_ value: Value) -> ProjectHealthValue<Value> {
        ProjectHealthValue(value: value, errorMessage: nil)
    }

    static func unavailable(_ errorMessage: String) -> ProjectHealthValue<Value> {
        ProjectHealthValue(value: nil, errorMessage: errorMessage)
    }

    static func capture(_ operation: () async throws -> Value) async -> ProjectHealthValue<Value> {
        do {
            return .available(try await operation())
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}

struct BeadsProjectContext: Codable, Equatable, Sendable {
    var backend: String?
    var bdVersion: String?
    var beadsDirectory: String?
    var cwdRepoRoot: String?
    var database: String?
    var doltMode: String?
    var isRedirected: Bool?
    var isWorktree: Bool?
    var projectID: String?
    var repoRoot: String?
    var role: String?
    var schemaVersion: Int?

    enum CodingKeys: String, CodingKey {
        case backend
        case bdVersion = "bd_version"
        case beadsDirectory = "beads_dir"
        case cwdRepoRoot = "cwd_repo_root"
        case database
        case doltMode = "dolt_mode"
        case isRedirected = "is_redirected"
        case isWorktree = "is_worktree"
        case projectID = "project_id"
        case repoRoot = "repo_root"
        case role
        case schemaVersion = "schema_version"
    }

    var storageSummary: String {
        let backendName = backend?.nilIfBlank ?? "Unknown"
        guard let doltMode = doltMode?.nilIfBlank else { return backendName }
        return "\(backendName) / \(doltMode)"
    }

    var usesCurrentEmbeddedDolt: Bool {
        backend == "dolt" && doltMode == "embedded"
    }

    func databasePath(projectURL: URL) -> String? {
        guard backend == "dolt", doltMode == "embedded" else {
            return beadsDirectory
        }
        let beadsURL = beadsDirectory.map(URL.init(fileURLWithPath:))
            ?? projectURL.appendingPathComponent(".beads", isDirectory: true)
        return beadsURL.appendingPathComponent("embeddeddolt", isDirectory: true).path
    }

    static func decode(from text: String) throws -> BeadsProjectContext {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(BeadsProjectContext.self, from: data)
    }
}

struct ProjectStorageConfigValue<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value?
    var errorMessage: String?

    var isUnavailable: Bool {
        errorMessage != nil
    }

    static func available(_ value: Value?) -> ProjectStorageConfigValue<Value> {
        ProjectStorageConfigValue(value: value, errorMessage: nil)
    }

    static func unavailable(_ errorMessage: String) -> ProjectStorageConfigValue<Value> {
        ProjectStorageConfigValue(value: nil, errorMessage: errorMessage)
    }

    func display(_ formatter: (Value?) -> String?) -> String? {
        guard errorMessage == nil else { return nil }
        return formatter(value)
    }
}

struct ProjectStorageConfig: Equatable, Sendable {
    var exportAutoStatus: ProjectStorageConfigValue<Bool>
    var exportPathStatus: ProjectStorageConfigValue<String>
    var exportIntervalStatus: ProjectStorageConfigValue<String>
    var exportGitAddStatus: ProjectStorageConfigValue<Bool>
    var importAutoStatus: ProjectStorageConfigValue<Bool>
    var federationRemoteStatus: ProjectStorageConfigValue<String>

    init(
        exportAuto: Bool?,
        exportPath: String?,
        exportInterval: String?,
        exportGitAdd: Bool?,
        importAuto: Bool?,
        federationRemote: String?
    ) {
        self.init(
            exportAutoStatus: .available(exportAuto),
            exportPathStatus: .available(exportPath),
            exportIntervalStatus: .available(exportInterval),
            exportGitAddStatus: .available(exportGitAdd),
            importAutoStatus: .available(importAuto),
            federationRemoteStatus: .available(federationRemote)
        )
    }

    init(
        exportAutoStatus: ProjectStorageConfigValue<Bool>,
        exportPathStatus: ProjectStorageConfigValue<String>,
        exportIntervalStatus: ProjectStorageConfigValue<String>,
        exportGitAddStatus: ProjectStorageConfigValue<Bool>,
        importAutoStatus: ProjectStorageConfigValue<Bool>,
        federationRemoteStatus: ProjectStorageConfigValue<String>
    ) {
        self.exportAutoStatus = exportAutoStatus
        self.exportPathStatus = exportPathStatus
        self.exportIntervalStatus = exportIntervalStatus
        self.exportGitAddStatus = exportGitAddStatus
        self.importAutoStatus = importAutoStatus
        self.federationRemoteStatus = federationRemoteStatus
    }

    var exportAuto: Bool? {
        exportAutoStatus.value
    }

    var exportPath: String? {
        exportPathStatus.value
    }

    var exportInterval: String? {
        exportIntervalStatus.value
    }

    var exportGitAdd: Bool? {
        exportGitAddStatus.value
    }

    var importAuto: Bool? {
        importAutoStatus.value
    }

    var federationRemote: String? {
        federationRemoteStatus.value
    }

    var exportSummary: String {
        guard !exportAutoStatus.isUnavailable else { return "Unavailable" }
        guard exportAuto != false else { return "Disabled" }
        return "Enabled"
    }

    var importSummary: String {
        guard !importAutoStatus.isUnavailable else { return "Unavailable" }
        return importAuto == true ? "Enabled" : "Disabled"
    }

    var federationSummary: String {
        guard !federationRemoteStatus.isUnavailable else { return "Unavailable" }
        return federationRemote?.nilIfBlank ?? "Not configured"
    }

    static func bool(from value: String?) -> Bool? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        switch normalized {
        case "true", "yes", "1", "on":
            return true
        case "false", "no", "0", "off":
            return false
        default:
            return nil
        }
    }

    static func configValue(from output: String, key: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("\(key) (not set") else { return nil }
        return trimmed
    }
}

struct BeadsHooksStatus: Equatable, Sendable {
    struct Hook: Identifiable, Equatable, Sendable {
        enum State: String, Equatable, Sendable {
            case installed
            case missing
            case other
        }

        var id: String { name }

        var name: String
        var state: State
        var detail: String
    }

    var hooks: [Hook]

    var missingHooks: [Hook] {
        hooks.filter { $0.state == .missing }
    }

    var hasMissingHooks: Bool {
        !missingHooks.isEmpty
    }

    var summary: String {
        guard !hooks.isEmpty else { return "Unavailable" }
        return hasMissingHooks ? "\(missingHooks.count) missing" : "Installed"
    }

    static func parse(from text: String) -> BeadsHooksStatus {
        let hooks = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Hook? in
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separatorIndex = trimmed.firstIndex(of: ":") else { return nil }

                let namePart = trimmed[..<separatorIndex]
                let name = namePart
                    .split(whereSeparator: \.isWhitespace)
                    .last
                    .map(String.init) ?? String(namePart)
                let detail = String(trimmed[trimmed.index(after: separatorIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !detail.isEmpty else { return nil }
                let lowercasedDetail = detail.lowercased()

                let state: Hook.State
                if lowercasedDetail.contains("not installed") || lowercasedDetail.contains("missing") {
                    state = .missing
                } else if lowercasedDetail.contains("installed") || lowercasedDetail.contains("ok") {
                    state = .installed
                } else {
                    state = .other
                }

                return Hook(name: name, state: state, detail: detail)
            }

        return BeadsHooksStatus(hooks: hooks)
    }
}

struct BeadsBackupStatus: Codable, Equatable, Sendable {
    struct Backup: Codable, Equatable, Sendable {
        var lastDoltCommit: String?
        var timestamp: String?

        enum CodingKeys: String, CodingKey {
            case lastDoltCommit = "last_dolt_commit"
            case timestamp
        }
    }

    struct DatabaseSize: Codable, Equatable, Sendable {
        var bytes: Int64?
        var human: String?

        var displayValue: String? {
            if let bytes {
                guard bytes > 0 else { return nil }
                return human?.nilIfBlank ?? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
            return human?.nilIfBlank
        }
    }

    struct DoltDestination: Codable, Equatable, Sendable {
        var configured: Bool?
    }

    var backup: Backup?
    var databaseSize: DatabaseSize?
    var dolt: DoltDestination?

    enum CodingKeys: String, CodingKey {
        case backup
        case databaseSize = "database_size"
        case dolt
    }

    var isConfigured: Bool {
        dolt?.configured == true
    }

    var hasBackupHistory: Bool {
        backup?.timestamp?.nilIfBlank != nil
    }

    var lastBackupDate: Date? {
        guard let timestamp = backup?.timestamp else { return nil }
        return Self.date(from: timestamp)
    }

    static func decode(from text: String) throws -> BeadsBackupStatus {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(BeadsBackupStatus.self, from: data)
    }

    private static func date(from string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }
}

struct ProjectSnapshotFileStatus: Equatable, Sendable {
    var url: URL
    var exists: Bool
    var size: Int64?
    var modifiedAt: Date?
    var activeDataSource: BeadsDataSource?

    var isActiveDataSource: Bool {
        activeDataSource?.kind == .jsonl
            && activeDataSource?.url.standardizedFileURL.path == url.standardizedFileURL.path
    }

    static func load(projectURL: URL, activeDataSource: BeadsDataSource?) -> ProjectSnapshotFileStatus {
        let url = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ProjectSnapshotFileStatus(
            url: url,
            exists: attributes != nil,
            size: attributes?[.size] as? Int64 ?? (attributes?[.size] as? NSNumber)?.int64Value,
            modifiedAt: attributes?[.modificationDate] as? Date,
            activeDataSource: activeDataSource
        )
    }
}
