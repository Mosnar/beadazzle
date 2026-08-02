import Foundation

struct BeadsSetupPreferenceRepository {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadIntent(projectURL: URL) -> BeadsSetupIntent? {
        let key = BeadazzlePreferenceKeys.beadsSetupIntent(projectURL: projectURL)
        guard let data = userDefaults.data(forKey: key),
              let intent = try? JSONDecoder().decode(BeadsSetupIntent.self, from: data),
              intent.version == BeadsSetupIntent.currentVersion else { return nil }
        return intent
    }

    func saveIntent(_ intent: BeadsSetupIntent, projectURL: URL) {
        guard let data = try? JSONEncoder().encode(intent) else { return }
        userDefaults.set(data, forKey: BeadazzlePreferenceKeys.beadsSetupIntent(projectURL: projectURL))
        userDefaults.removeObject(
            forKey: BeadazzlePreferenceKeys.beadsSetupDismissedFingerprint(projectURL: projectURL)
        )
    }

    func dismissedFingerprint(projectURL: URL) -> String? {
        let key = BeadazzlePreferenceKeys.beadsSetupDismissedFingerprint(projectURL: projectURL)
        return userDefaults.string(forKey: key)
    }

    func saveDismissedFingerprint(_ fingerprint: String?, projectURL: URL) {
        let key = BeadazzlePreferenceKeys.beadsSetupDismissedFingerprint(projectURL: projectURL)
        if let fingerprint {
            userDefaults.set(fingerprint, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }
}
