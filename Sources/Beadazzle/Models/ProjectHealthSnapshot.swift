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
        environment: BeadsProjectEnvironment?,
        activeDataSource: BeadsDataSource?,
        commands: any BeadsCommanding
    ) async -> ProjectHealthSnapshot {
        let snapshotFile = ProjectSnapshotFileStatus.load(
            projectURL: projectURL,
            beadsDirectoryURL: environment?.beadsDirectoryURL,
            activeDataSource: activeDataSource
        )

        async let storageConfig = ProjectHealthValue.capture {
            try await commands.loadProjectStorageConfig(projectURL: projectURL)
        }
        async let hooks = ProjectHealthValue.capture {
            try await commands.loadHooksStatus(projectURL: projectURL)
        }
        async let backup = ProjectHealthValue.capture {
            try await commands.loadBackupStatus(projectURL: projectURL)
        }

        let context: ProjectHealthValue<BeadsProjectContext>
        if let environment {
            context = .available(environment.context)
        } else {
            context = await ProjectHealthValue.capture {
                try await commands.loadProjectContext(projectURL: projectURL)
            }
        }

        return ProjectHealthSnapshot(
            loadedAt: Date(),
            context: context,
            storageConfig: await storageConfig,
            hooks: await hooks,
            backup: await backup,
            snapshotFile: snapshotFile
        )
    }
}

struct ProjectPreflightHealth: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ready
        case info
        case warning
        case blocked
        case checking
    }

    enum CheckID: String, Equatable, Sendable {
        case bdCLI
        case readableData
        case snapshotFreshness
        case exportConfiguration
        case gitHooks
        case backup
    }

    struct Check: Identifiable, Equatable, Sendable {
        var id: CheckID
        var title: String
        var status: Status
        var summary: String
        var detail: String?
        var actionHint: String?
    }

    var status: Status
    var title: String
    var summary: String
    var checks: [Check]

    static func evaluate(
        projectURL: URL?,
        missingDataSourceURL: URL?,
        activeDataSource: BeadsDataSource?,
        snapshotFreshness: ProjectSnapshotFreshness,
        health: ProjectHealthSnapshot?,
        automaticallyRefreshesExternalChanges: Bool,
        isLoading: Bool
    ) -> ProjectPreflightHealth {
        let checks = [
            bdCLICheck(health: health, isLoading: isLoading),
            readableDataCheck(projectURL: projectURL, missingDataSourceURL: missingDataSourceURL, activeDataSource: activeDataSource, isLoading: isLoading),
            snapshotFreshnessCheck(missingDataSourceURL: missingDataSourceURL, activeDataSource: activeDataSource, freshness: snapshotFreshness, health: health, isLoading: isLoading),
            exportConfigurationCheck(
                health: health,
                activeDataSource: activeDataSource,
                automaticallyRefreshesExternalChanges: automaticallyRefreshesExternalChanges,
                isLoading: isLoading
            ),
            gitHooksCheck(health: health, isLoading: isLoading),
            backupCheck(health: health, isLoading: isLoading)
        ]
        let status = overallStatus(for: checks)
        return ProjectPreflightHealth(
            status: status,
            title: title(for: status),
            summary: summary(for: status),
            checks: checks
        )
    }

    private static func overallStatus(for checks: [Check]) -> Status {
        if checks.contains(where: { $0.status == .blocked }) {
            return .blocked
        }
        if checks.contains(where: { $0.status == .checking }) {
            return .checking
        }
        if checks.contains(where: { $0.status == .warning }) {
            return .warning
        }
        return .ready
    }

    private static func title(for status: Status) -> String {
        switch status {
        case .ready, .info:
            "Ready for Beadazzle"
        case .warning:
            "Pre-flight Needs Attention"
        case .blocked:
            "Pre-flight Blocked"
        case .checking:
            "Checking Project Setup"
        }
    }

    private static func summary(for status: Status) -> String {
        switch status {
        case .ready, .info:
            "Beadazzle can read this project and route writes through bd."
        case .warning:
            "The project is usable, but one or more setup checks could cause stale data or rough edges."
        case .blocked:
            "Beadazzle needs setup before this project can be used safely."
        case .checking:
            "Beadazzle is checking bd, data, snapshots, hooks, and backup state."
        }
    }

    private static func bdCLICheck(health: ProjectHealthSnapshot?, isLoading: Bool) -> Check {
        if let context = health?.context.value {
            let version = context.bdVersion?.nilIfBlank.map { "bd \($0)" } ?? "bd available"
            return Check(
                id: .bdCLI,
                title: "bd CLI",
                status: .ready,
                summary: version,
                detail: context.repoRoot?.nilIfBlank.map { "Project context loaded for \($0)." },
                actionHint: nil
            )
        }
        if let errorMessage = health?.context.errorMessage {
            return Check(
                id: .bdCLI,
                title: "bd CLI",
                status: .blocked,
                summary: "Cannot run bd for this project",
                detail: errorMessage,
                actionHint: "Choose a bd executable in Settings."
            )
        }
        return pendingCheck(
            id: .bdCLI,
            title: "bd CLI",
            isLoading: isLoading,
            unloadedSummary: "bd status has not loaded"
        )
    }

    private static func readableDataCheck(
        projectURL: URL?,
        missingDataSourceURL: URL?,
        activeDataSource: BeadsDataSource?,
        isLoading: Bool
    ) -> Check {
        guard projectURL != nil else {
            return Check(
                id: .readableData,
                title: "Beads Data",
                status: .blocked,
                summary: "No project selected",
                detail: nil,
                actionHint: "Open a project folder."
            )
        }
        if missingDataSourceURL != nil {
            return Check(
                id: .readableData,
                title: "Beads Data",
                status: .blocked,
                summary: "Beads is not initialized",
                detail: "The selected folder does not have a readable snapshot in its active Beads tracker directory.",
                actionHint: "Initialize Beads for this project."
            )
        }
        if let activeDataSource {
            return Check(
                id: .readableData,
                title: "Beads Data",
                status: .ready,
                summary: "Reading JSONL snapshot",
                detail: activeDataSource.displayPath,
                actionHint: nil
            )
        }
        return pendingCheck(
            id: .readableData,
            title: "Beads Data",
            isLoading: isLoading,
            unloadedSummary: "No readable Beads data source found",
            unloadedStatus: .blocked,
            unloadedActionHint: "Initialize Beads or export a snapshot."
        )
    }

    private static func snapshotFreshnessCheck(
        missingDataSourceURL: URL?,
        activeDataSource: BeadsDataSource?,
        freshness: ProjectSnapshotFreshness,
        health: ProjectHealthSnapshot?,
        isLoading: Bool
    ) -> Check {
        if missingDataSourceURL != nil {
            return Check(
                id: .snapshotFreshness,
                title: "Readable Snapshot",
                status: .blocked,
                summary: "No snapshot yet",
                detail: "Beadazzle has no Beads data to read for this folder.",
                actionHint: "Initialize Beads for this project."
            )
        }
        switch freshness.state {
        case .current:
            return Check(
                id: .snapshotFreshness,
                title: "Readable Snapshot",
                status: .ready,
                summary: freshness.message,
                detail: health?.snapshotFile.url.path,
                actionHint: nil
            )
        case .refreshing:
            return Check(
                id: .snapshotFreshness,
                title: "Readable Snapshot",
                status: .checking,
                summary: freshness.message,
                detail: freshness.detail,
                actionHint: nil
            )
        case .possiblyStale:
            return Check(
                id: .snapshotFreshness,
                title: "Readable Snapshot",
                status: .warning,
                summary: freshness.message,
                detail: freshness.detail,
                actionHint: "Export Snapshot"
            )
        case .unknown:
            let snapshotExists = health?.snapshotFile.exists == true
            return Check(
                id: .snapshotFreshness,
                title: "Readable Snapshot",
                status: isLoading ? .checking : (snapshotExists ? .warning : .blocked),
                summary: isLoading ? "Checking snapshot freshness" : (snapshotExists ? freshness.message : "JSONL snapshot missing"),
                detail: freshness.detail ?? health?.snapshotFile.url.path,
                actionHint: snapshotExists ? "Refresh Status" : "Export Snapshot"
            )
        }
    }

    private static func exportConfigurationCheck(
        health: ProjectHealthSnapshot?,
        activeDataSource: BeadsDataSource?,
        automaticallyRefreshesExternalChanges: Bool,
        isLoading: Bool
    ) -> Check {
        if let config = health?.storageConfig.value {
            if let errorMessage = config.exportAutoStatus.errorMessage {
                return configWarning(
                    id: .exportConfiguration,
                    title: "Export Config",
                    summary: "Cannot read export.auto",
                    detail: errorMessage
                )
            }
            if config.exportAuto == false {
                if automaticallyRefreshesExternalChanges {
                    return Check(
                        id: .exportConfiguration,
                        title: "Export Config",
                        status: .ready,
                        summary: "Beadazzle refreshes external changes",
                        detail: activeDataSource?.kind == .jsonl
                            ? "bd automatic export is disabled, so Beadazzle exports after detecting external changes."
                            : "Beadazzle reloads the active data source after detecting external changes.",
                        actionHint: nil
                    )
                }
                return Check(
                    id: .exportConfiguration,
                    title: "Export Config",
                    status: .warning,
                    summary: "Automatic export is disabled",
                    detail: "External bd writes require a manual snapshot export while both automatic refresh options are disabled.",
                    actionHint: "Enable automatic external refresh or export.auto."
                )
            }
            if let errorMessage = config.exportPathStatus.errorMessage {
                return configWarning(
                    id: .exportConfiguration,
                    title: "Export Config",
                    summary: "Cannot read export.path",
                    detail: errorMessage
                )
            }
            guard let exportPath = config.exportPath?.nilIfBlank else {
                return Check(
                    id: .exportConfiguration,
                    title: "Export Config",
                    status: .warning,
                    summary: "Export path is not configured",
                    detail: "Beadazzle expects a readable JSONL snapshot such as issues.jsonl in the active tracker directory.",
                    actionHint: "Set export.path in bd config."
                )
            }
            return Check(
                id: .exportConfiguration,
                title: "Export Config",
                status: .ready,
                summary: "Auto export to \(exportPath)",
                detail: nil,
                actionHint: nil
            )
        }
        if let errorMessage = health?.storageConfig.errorMessage {
            return configWarning(
                id: .exportConfiguration,
                title: "Export Config",
                summary: "Storage config unavailable",
                detail: errorMessage
            )
        }
        return pendingCheck(
            id: .exportConfiguration,
            title: "Export Config",
            isLoading: isLoading,
            unloadedSummary: "Storage config has not loaded"
        )
    }

    private static func gitHooksCheck(health: ProjectHealthSnapshot?, isLoading: Bool) -> Check {
        if let storageError = health?.storageConfig.errorMessage {
            return Check(
                id: .gitHooks,
                title: "Git Integration",
                status: .warning,
                summary: "Git integration status unavailable",
                detail: storageError,
                actionHint: "Refresh Status"
            )
        }
        if let noGitOperationsError = health?.storageConfig.value?.noGitOperationsStatus.errorMessage {
            return Check(
                id: .gitHooks,
                title: "Git Integration",
                status: .warning,
                summary: "Git integration status unavailable",
                detail: noGitOperationsError,
                actionHint: "Refresh Status"
            )
        }
        if health?.storageConfig.value?.usesStealthMode == true {
            return Check(
                id: .gitHooks,
                title: "Git Integration",
                status: .info,
                summary: "Disabled by stealth mode",
                detail: "Beads files stay local and Git hooks are intentionally not installed.",
                actionHint: nil
            )
        }
        if let hooks = health?.hooks.value {
            guard !hooks.hooks.isEmpty else {
                return Check(
                    id: .gitHooks,
                    title: "Git Hooks",
                    status: .warning,
                    summary: "Hook status unavailable",
                    detail: nil,
                    actionHint: "Refresh Status"
                )
            }
            if hooks.hasMissingHooks {
                return Check(
                    id: .gitHooks,
                    title: "Git Hooks",
                    status: .warning,
                    summary: hooks.summary,
                    detail: hooks.missingHooks.map(\.name).joined(separator: ", "),
                    actionHint: "Install Hooks"
                )
            }
            return Check(
                id: .gitHooks,
                title: "Git Hooks",
                status: .ready,
                summary: "Installed",
                detail: nil,
                actionHint: nil
            )
        }
        if let errorMessage = health?.hooks.errorMessage {
            return Check(
                id: .gitHooks,
                title: "Git Hooks",
                status: .warning,
                summary: "Hook status unavailable",
                detail: errorMessage,
                actionHint: "Refresh Status"
            )
        }
        return pendingCheck(
            id: .gitHooks,
            title: "Git Hooks",
            isLoading: isLoading,
            unloadedSummary: "Hook status has not loaded"
        )
    }

    private static func backupCheck(health: ProjectHealthSnapshot?, isLoading: Bool) -> Check {
        if let backup = health?.backup.value {
            if backup.isConfigured {
                return Check(
                    id: .backup,
                    title: "Backup",
                    status: .ready,
                    summary: backup.hasBackupHistory ? "Configured with backup history" : "Configured",
                    detail: backup.backup?.timestamp,
                    actionHint: nil
                )
            }
            return Check(
                id: .backup,
                title: "Backup",
                status: .info,
                summary: "Not configured",
                detail: "Backups are optional for Beadazzle, but useful before large tracker changes.",
                actionHint: nil
            )
        }
        if let errorMessage = health?.backup.errorMessage {
            return Check(
                id: .backup,
                title: "Backup",
                status: .info,
                summary: "Backup status unavailable",
                detail: errorMessage,
                actionHint: nil
            )
        }
        return pendingCheck(
            id: .backup,
            title: "Backup",
            isLoading: isLoading,
            unloadedSummary: "Backup status has not loaded",
            unloadedStatus: .info
        )
    }

    private static func configWarning(id: CheckID, title: String, summary: String, detail: String?) -> Check {
        Check(
            id: id,
            title: title,
            status: .warning,
            summary: summary,
            detail: detail,
            actionHint: "Refresh Status"
        )
    }

    private static func pendingCheck(
        id: CheckID,
        title: String,
        isLoading: Bool,
        unloadedSummary: String,
        unloadedStatus: Status = .warning,
        unloadedActionHint: String? = "Refresh Status"
    ) -> Check {
        Check(
            id: id,
            title: title,
            status: isLoading ? .checking : unloadedStatus,
            summary: isLoading ? "Checking \(title.lowercased())" : unloadedSummary,
            detail: nil,
            actionHint: isLoading ? nil : unloadedActionHint
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
    var noGitOperationsStatus: ProjectStorageConfigValue<Bool>

    init(
        exportAuto: Bool?,
        exportPath: String?,
        exportInterval: String?,
        exportGitAdd: Bool?,
        importAuto: Bool?,
        federationRemote: String?,
        noGitOperations: Bool? = nil
    ) {
        self.init(
            exportAutoStatus: .available(exportAuto),
            exportPathStatus: .available(exportPath),
            exportIntervalStatus: .available(exportInterval),
            exportGitAddStatus: .available(exportGitAdd),
            importAutoStatus: .available(importAuto),
            federationRemoteStatus: .available(federationRemote),
            noGitOperationsStatus: .available(noGitOperations)
        )
    }

    init(
        exportAutoStatus: ProjectStorageConfigValue<Bool>,
        exportPathStatus: ProjectStorageConfigValue<String>,
        exportIntervalStatus: ProjectStorageConfigValue<String>,
        exportGitAddStatus: ProjectStorageConfigValue<Bool>,
        importAutoStatus: ProjectStorageConfigValue<Bool>,
        federationRemoteStatus: ProjectStorageConfigValue<String>,
        noGitOperationsStatus: ProjectStorageConfigValue<Bool> = .available(nil)
    ) {
        self.exportAutoStatus = exportAutoStatus
        self.exportPathStatus = exportPathStatus
        self.exportIntervalStatus = exportIntervalStatus
        self.exportGitAddStatus = exportGitAddStatus
        self.importAutoStatus = importAutoStatus
        self.federationRemoteStatus = federationRemoteStatus
        self.noGitOperationsStatus = noGitOperationsStatus
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

    var noGitOperations: Bool? {
        noGitOperationsStatus.value
    }

    var usesStealthMode: Bool {
        noGitOperations == true
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

    static func load(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        activeDataSource: BeadsDataSource?
    ) -> ProjectSnapshotFileStatus {
        let url = beadsDirectoryURL.map {
            BeadsCommandService.exportedIssuesJSONLURL(beadsDirectoryURL: $0)
        }
            ?? BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
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
