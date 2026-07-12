import Foundation

struct BeadSavedViewLoadResult {
    var tree = BeadSavedViewTree()
    var persistenceState = BeadSavedViewPersistenceState.ready
    var rebuildsCounts = false

    var rootNodes: [BeadSavedViewNode] { tree.rootNodes }
    var views: [BeadSavedView] { tree.savedViews }
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
        guard header.version == BeadSavedViewsPayload.currentVersion else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .unsupportedVersion,
                message: header.version > BeadSavedViewsPayload.currentVersion
                    ? "Bookmarks require a newer version of Beadazzle."
                    : "Bookmarks use an older format that this build cannot migrate."
            ))
        }
        guard var recovered = try? BeadSavedViewTree.decodeRecovering(from: data) else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(persistenceState: .readOnly(
                reason: .corrupt,
                message: "Bookmarks could not be read. The original data was preserved for recovery."
            ))
        }

        recovered.tree.normalize(view: Self.normalized, folder: Self.normalized)
        let recoveryIssueCount = recovered.recoveryIssueCount
        if recoveryIssueCount > 0 {
            preserveRecoveryData(data, key: key)
        }
        return BeadSavedViewLoadResult(
            tree: recovered.tree,
            persistenceState: recoveryIssueCount > 0
                ? .recovered(
                    issueCount: recoveryIssueCount,
                    message: "\(recoveryIssueCount) bookmark item\(recoveryIssueCount == 1 ? " was" : "s were") skipped because the saved data was invalid. A recovery copy was preserved."
                )
                : .ready,
            rebuildsCounts: true
        )
    }

    @discardableResult
    func save(_ tree: BeadSavedViewTree, projectURL: URL) -> Bool {
        guard tree.hasUniqueNodeIDs,
              tree.savedViews.allSatisfy({
                  $0.hasValidQuery && $0.query.advancedPredicate?.hasUniqueNodeIDs != false
              }),
              let data = try? JSONEncoder().encode(BeadSavedViewsPayload(rootNodes: tree.rootNodes)) else {
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
        view.name = name.isEmpty ? "Saved View" : name
        view.symbolName = BeadSavedViewSymbols.normalized(view.symbolName)
        if case .manual(var manual) = view.ordering {
            var seenIssueIDs: Set<String> = []
            manual.issueIDs = manual.issueIDs.compactMap { issueID in
                let normalized = issueID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, seenIssueIDs.insert(normalized).inserted else { return nil }
                return normalized
            }
            view.ordering = .manual(manual)
        }
        return view
    }

    static func normalized(_ folder: BeadSavedViewFolder) -> BeadSavedViewFolder {
        var folder = folder
        let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = name.isEmpty ? "Folder" : name
        return folder
    }

    private func preserveRecoveryData(_ data: Data, key: String) {
        let recoveryKey = "\(key).Recovery"
        if userDefaults.data(forKey: recoveryKey) == nil {
            userDefaults.set(data, forKey: recoveryKey)
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
