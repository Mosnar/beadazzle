import Foundation

struct BeadSemanticDefinitionsCacheEntry: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version = currentVersion
    var definitions: BeadSemanticDefinitions
    var refreshedAt: Date
}

struct BeadSemanticDefinitionsCache: Equatable, Sendable {
    var trackerDirectoryURL: URL
    var entry: BeadSemanticDefinitionsCacheEntry
}

/// Small, per-tracker cache for status/type definitions.
///
/// Embedded Dolt startup makes the two metadata commands disproportionately expensive.
/// A project-to-tracker route restores the cache before `bd context` finishes, while the
/// loader validates that route against the newly resolved effective tracker directory.
@MainActor
final class BeadSemanticDefinitionsRepository {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func load(projectURL: URL) -> BeadSemanticDefinitionsCache? {
        let routeKey = BeadazzlePreferenceKeys.semanticDefinitionsTrackerRoute(projectURL: projectURL)
        guard let trackerPath = userDefaults.string(forKey: routeKey), !trackerPath.isEmpty else {
            return nil
        }
        let trackerDirectoryURL = URL(fileURLWithPath: trackerPath, isDirectory: true)
            .standardizedFileURL
        let key = BeadazzlePreferenceKeys.semanticDefinitions(
            trackerDirectoryURL: trackerDirectoryURL
        )
        guard let data = userDefaults.data(forKey: key),
              let entry = try? JSONDecoder().decode(BeadSemanticDefinitionsCacheEntry.self, from: data),
              entry.version == BeadSemanticDefinitionsCacheEntry.currentVersion
        else {
            return nil
        }
        return BeadSemanticDefinitionsCache(
            trackerDirectoryURL: trackerDirectoryURL,
            entry: entry
        )
    }

    func save(
        _ definitions: BeadSemanticDefinitions,
        projectURL: URL,
        trackerDirectoryURL: URL,
        refreshedAt: Date = Date()
    ) {
        let trackerDirectoryURL = trackerDirectoryURL.standardizedFileURL
        let entry = BeadSemanticDefinitionsCacheEntry(
            definitions: definitions,
            refreshedAt: refreshedAt
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        userDefaults.set(
            data,
            forKey: BeadazzlePreferenceKeys.semanticDefinitions(
                trackerDirectoryURL: trackerDirectoryURL
            )
        )
        userDefaults.set(
            trackerDirectoryURL.path,
            forKey: BeadazzlePreferenceKeys.semanticDefinitionsTrackerRoute(projectURL: projectURL)
        )
        userDefaults.removeObject(
            forKey: BeadazzlePreferenceKeys.legacySemanticDefinitions(projectURL: projectURL)
        )
    }

    func reset(projectURL: URL, trackerDirectoryURL: URL? = nil) {
        let routeKey = BeadazzlePreferenceKeys.semanticDefinitionsTrackerRoute(projectURL: projectURL)
        let routedTrackerURL = userDefaults.string(forKey: routeKey).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let trackerDirectoryURL = trackerDirectoryURL ?? routedTrackerURL {
            userDefaults.removeObject(
                forKey: BeadazzlePreferenceKeys.semanticDefinitions(
                    trackerDirectoryURL: trackerDirectoryURL
                )
            )
        }
        userDefaults.removeObject(forKey: routeKey)
        userDefaults.removeObject(
            forKey: BeadazzlePreferenceKeys.legacySemanticDefinitions(projectURL: projectURL)
        )
    }
}
