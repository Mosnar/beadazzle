import Foundation

struct BeadSavedViewLoadResult {
    var views: [BeadSavedView] = []
    var persistenceState = BeadSavedViewPersistenceState.ready
    var rebuildsCounts = false

    var hasUnsupportedVersion: Bool { persistenceState.hasUnsupportedVersion }
    var isCorrupt: Bool { persistenceState.isCorrupt }
    var recoveryIssueCount: Int { persistenceState.recoveryIssueCount }
    var message: String? { persistenceState.message }
}

@MainActor
final class BeadSavedViewRepository {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func load(projectURL: URL) -> BeadSavedViewLoadResult {
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        guard let data = userDefaults.data(forKey: key) else { return BeadSavedViewLoadResult() }
        guard let header = try? JSONDecoder().decode(PayloadHeader.self, from: data) else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .corrupt,
                message: "Bookmarks could not be read. The original data was preserved for recovery."
            ))
        }

        switch header.version {
        case 1:
            return migrateVersionOne(data, key: key, projectURL: projectURL)
        case BeadSavedViewsPayload.currentVersion:
            return loadCurrentVersion(data, key: key)
        default:
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .unsupportedVersion,
                message: header.version > BeadSavedViewsPayload.currentVersion
                    ? "Bookmarks require a newer version of Beadazzle."
                    : "Bookmarks use an older format that this build cannot migrate."
            ))
        }
    }

    private func loadCurrentVersion(_ data: Data, key: String) -> BeadSavedViewLoadResult {
        guard let decoded = try? RecoveringSavedViewsPayload.decode(from: data) else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .corrupt,
                message: "Bookmarks could not be read. The original data was preserved for recovery."
            ))
        }

        let normalized = Self.normalizedRecovering(
            decoded.views.map(Self.normalized),
            initialIssueCount: decoded.recoveryIssueCount
        )
        let recoveryIssueCount = normalized.recoveryIssueCount
        if recoveryIssueCount > 0 {
            preserveRecoveryData(data, key: key)
        }
        return BeadSavedViewLoadResult(
            views: normalized.views,
            persistenceState: recoveryIssueCount > 0
                ? .recovered(
                    issueCount: recoveryIssueCount,
                    message: "\(recoveryIssueCount) bookmark item\(recoveryIssueCount == 1 ? " was" : "s were") skipped because the saved data was invalid. A recovery copy was preserved."
                )
                : .ready,
            rebuildsCounts: true
        )
    }

    private func migrateVersionOne(
        _ data: Data,
        key: String,
        projectURL: URL
    ) -> BeadSavedViewLoadResult {
        guard var recovered = try? BeadSavedViewTree.decodeRecovering(from: data) else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .corrupt,
                message: "Bookmarks could not be migrated. The original data was preserved for recovery."
            ))
        }

        recovered.tree.normalize(view: Self.normalized, folder: Self.normalized)
        let normalized = Self.normalizedRecovering(
            recovered.tree.savedViews,
            initialIssueCount: recovered.recoveryIssueCount
        )
        preserveMigrationRecoveryData(data, key: key)
        guard save(normalized.views, projectURL: projectURL) else {
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .corrupt,
                message: "Bookmarks could not be migrated. The original data was preserved for recovery."
            ))
        }

        return BeadSavedViewLoadResult(
            views: normalized.views,
            persistenceState: normalized.recoveryIssueCount > 0
                ? .recovered(
                    issueCount: normalized.recoveryIssueCount,
                    message: "\(normalized.recoveryIssueCount) bookmark item\(normalized.recoveryIssueCount == 1 ? " was" : "s were") skipped while migrating. A recovery copy was preserved."
                )
                : .ready,
            rebuildsCounts: true
        )
    }

    @discardableResult
    func save(_ views: [BeadSavedView], projectURL: URL) -> Bool {
        let normalizedViews = views.map(Self.normalized)
        guard Set(normalizedViews.map(\.id)).count == normalizedViews.count,
              normalizedViews.allSatisfy({
                  $0.hasValidQuery
                      && $0.smartQuery?.advancedPredicate?.hasUniqueNodeIDs != false
              }),
              let data = try? JSONEncoder().encode(BeadSavedViewsPayload(views: normalizedViews))
        else {
            return false
        }
        userDefaults.set(data, forKey: BeadazzlePreferenceKeys.savedViews(projectURL: projectURL))
        return true
    }

    func reset(projectURL: URL) {
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        if let data = userDefaults.data(forKey: key) {
            archiveRecoveryData(data, key: key)
        }
        userDefaults.removeObject(forKey: key)
    }

    static func normalized(_ view: BeadSavedView) -> BeadSavedView {
        var view = view
        let name = view.name.trimmingCharacters(in: .whitespacesAndNewlines)
        view.name = name.isEmpty ? (view.isFolder ? "Folder" : "Saved View") : name
        view.symbolName = BeadSavedViewSymbols.normalized(view.symbolName)
        if case .folder(var folder) = view.content {
            var seenIssueIDs: Set<String> = []
            folder.orderedIssueIDs = folder.orderedIssueIDs.compactMap { issueID in
                let normalized = issueID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seenIssueIDs.insert(normalized).inserted else { return nil }
                return normalized
            }
            view.content = .folder(folder)
        }
        return view
    }

    static func normalized(_ folder: BeadSavedViewFolder) -> BeadSavedViewFolder {
        var folder = folder
        let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = name.isEmpty ? "Folder" : name
        return folder
    }

    private static func normalizedRecovering(
        _ views: [BeadSavedView],
        initialIssueCount: Int
    ) -> (views: [BeadSavedView], recoveryIssueCount: Int) {
        var seenIDs: Set<UUID> = []
        var recoveryIssueCount = initialIssueCount
        let uniqueViews = views.filter { view in
            guard seenIDs.insert(view.id).inserted else {
                recoveryIssueCount += 1
                return false
            }
            return true
        }
        return (uniqueViews, recoveryIssueCount)
    }

    private func preserveRecoveryData(_ data: Data, key: String) {
        let recoveryKey = "\(key).Recovery"
        if userDefaults.data(forKey: recoveryKey) == nil {
            userDefaults.set(data, forKey: recoveryKey)
        }
    }

    private func preserveMigrationRecoveryData(_ data: Data, key: String) {
        let recoveryKey = "\(key).Recovery"
        if userDefaults.data(forKey: recoveryKey) == nil {
            userDefaults.set(data, forKey: recoveryKey)
        } else {
            archiveRecoveryData(data, key: key)
        }
    }

    private func archiveRecoveryData(_ data: Data, key: String) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        userDefaults.set(data, forKey: "\(key).Recovery.\(timestamp).\(UUID().uuidString)")
    }
}

private struct PayloadHeader: Decodable {
    var version: Int
}

private struct RecoveringSavedViewsPayload: Decodable {
    var views: [BeadSavedView]
    var recoveryIssueCount: Int

    private enum CodingKeys: String, CodingKey { case version, views }

    static func decode(from data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == BeadSavedViewsPayload.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unexpected saved-view payload version"
            )
        }

        var viewsContainer = try container.nestedUnkeyedContainer(forKey: .views)
        var decodedViews: [BeadSavedView] = []
        var skipped = 0
        while !viewsContainer.isAtEnd {
            let itemDecoder = try viewsContainer.superDecoder()
            do {
                decodedViews.append(try BeadSavedView(from: itemDecoder))
            } catch {
                skipped += 1
            }
        }
        views = decodedViews
        recoveryIssueCount = skipped
    }
}
