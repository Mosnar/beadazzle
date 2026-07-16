import Foundation

/// Per-project persistence for the last workspace state (view, filters, sort, selection, expansion).
///
/// Modeled on `BeadSavedViewRepository`: the stored blob is a versioned JSON payload keyed by the
/// normalized project path. Loading is intentionally lossy — a missing, corrupt, or version-mismatched
/// payload returns `nil` so the caller simply falls back to defaults, and a recovery copy of the
/// original bytes is preserved so nothing is silently destroyed.
@MainActor
final class BeadWorkspaceStateRepository {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func load(projectURL: URL) -> BeadWorkspaceStatePayload? {
        let key = BeadazzlePreferenceKeys.workspaceState(projectURL: projectURL)
        guard let data = userDefaults.data(forKey: key) else { return nil }

        guard let header = try? JSONDecoder().decode(PayloadHeader.self, from: data) else {
            preserveRecoveryData(data, key: key)
            return nil
        }
        guard header.version == BeadWorkspaceStatePayload.currentVersion else {
            preserveRecoveryData(data, key: key)
            return nil
        }
        guard let payload = try? JSONDecoder().decode(BeadWorkspaceStatePayload.self, from: data) else {
            preserveRecoveryData(data, key: key)
            return nil
        }
        return payload
    }

    @discardableResult
    func save(_ payload: BeadWorkspaceStatePayload, projectURL: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        userDefaults.set(data, forKey: BeadazzlePreferenceKeys.workspaceState(projectURL: projectURL))
        return true
    }

    func reset(projectURL: URL) {
        let key = BeadazzlePreferenceKeys.workspaceState(projectURL: projectURL)
        if let data = userDefaults.data(forKey: key) {
            archiveRecoveryData(data, key: key)
        }
        userDefaults.removeObject(forKey: key)
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
