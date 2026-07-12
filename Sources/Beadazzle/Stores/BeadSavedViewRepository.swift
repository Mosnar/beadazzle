import Foundation

struct BeadSavedViewLoadResult {
    var views: [BeadSavedView] = []
    var hasUnsupportedVersion = false
    var isCorrupt = false
    var recoveryIssueCount = 0
    var message: String?
    var rebuildsCounts = false
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(
                isCorrupt: true,
                recoveryIssueCount: 1,
                message: "Bookmarks could not be read. The original data was preserved for recovery."
            )
        }
        guard version == BeadSavedViewsPayload.currentVersion else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(
                hasUnsupportedVersion: true,
                message: version > BeadSavedViewsPayload.currentVersion
                    ? "Bookmarks require a newer version of Beadazzle."
                    : "Bookmarks use an older format that this build cannot migrate."
            )
        }
        guard let rawViews = object["views"] as? [Any] else {
            preserveRecoveryData(data, key: key)
            return BeadSavedViewLoadResult(
                isCorrupt: true,
                recoveryIssueCount: 1,
                message: "Bookmarks could not be read. The original data was preserved for recovery."
            )
        }

        let decoder = JSONDecoder()
        var seenViewIDs: Set<UUID> = []
        let views = rawViews.compactMap { rawView -> BeadSavedView? in
            guard JSONSerialization.isValidJSONObject(rawView),
                  let itemData = try? JSONSerialization.data(withJSONObject: rawView),
                  let view = try? decoder.decode(BeadSavedView.self, from: itemData),
                  view.hasValidQuery,
                  view.filter.advancedPredicate?.hasUniqueNodeIDs != false,
                  seenViewIDs.insert(view.id).inserted else {
                return nil
            }
            return Self.normalized(view)
        }
        let recoveryIssueCount = rawViews.count - views.count
        if recoveryIssueCount > 0 {
            preserveRecoveryData(data, key: key)
        }
        return BeadSavedViewLoadResult(
            views: views,
            recoveryIssueCount: recoveryIssueCount,
            message: recoveryIssueCount > 0
                ? "\(recoveryIssueCount) bookmark\(recoveryIssueCount == 1 ? " was" : "s were") skipped because the saved data was invalid. A recovery copy was preserved."
                : nil,
            rebuildsCounts: true
        )
    }

    func save(_ views: [BeadSavedView], projectURL: URL) {
        guard let data = try? JSONEncoder().encode(BeadSavedViewsPayload(views: views)) else { return }
        userDefaults.set(data, forKey: BeadazzlePreferenceKeys.savedViews(projectURL: projectURL))
    }

    static func normalized(_ view: BeadSavedView) -> BeadSavedView {
        var view = view
        let name = view.name.trimmingCharacters(in: .whitespacesAndNewlines)
        view.name = name.isEmpty ? "Saved View" : name
        view.symbolName = BeadSavedViewSymbols.normalized(view.symbolName)
        return view
    }

    private func preserveRecoveryData(_ data: Data, key: String) {
        let recoveryKey = "\(key).Recovery"
        if userDefaults.data(forKey: recoveryKey) == nil {
            userDefaults.set(data, forKey: recoveryKey)
        }
    }
}
