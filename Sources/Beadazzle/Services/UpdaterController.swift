import Combine
import Foundation
import Sparkle

/// Owns the Sparkle updater for the app.
///
/// Beadazzle ships outside the App Store and is not sandboxed, so the updater
/// runs without XPC services (those are stripped from the embedded framework in
/// `build_app_bundle.sh`). The "receive beta updates" preference is bridged into
/// Sparkle's channel selection through `UpdaterChannelDelegate`, which Sparkle
/// consults on every check — no restart or re-registration needed when it flips.
/// Local builds without a baked-in Sparkle public key do not start Sparkle; the
/// matching menu and settings controls are hidden because those builds cannot
/// verify or install release updates.
@MainActor
final class UpdaterController: ObservableObject {
    let standardUpdaterController: SPUStandardUpdaterController?
    private let channelDelegate: UpdaterChannelDelegate?
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        self.userDefaults = userDefaults

        if SparkleUpdateConfiguration(infoDictionary: infoDictionary) != nil {
            let channelDelegate = UpdaterChannelDelegate(userDefaults: userDefaults)
            self.channelDelegate = channelDelegate
            // startingUpdater: true begins scheduled background checks immediately.
            self.standardUpdaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: channelDelegate,
                userDriverDelegate: nil
            )
        } else {
            self.channelDelegate = nil
            self.standardUpdaterController = nil
        }
    }

    var updater: SPUUpdater? { standardUpdaterController?.updater }

    var isUpdateCheckingAvailable: Bool { updater != nil }

    /// Bound by the Updates settings pane. Sparkle persists this itself.
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            guard let updater else { return }
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Opts the app into Sparkle's `beta` appcast channel.
    var receivesBetaUpdates: Bool {
        get { userDefaults.bool(forKey: BeadazzlePreferenceKeys.receivesBetaUpdates) }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: BeadazzlePreferenceKeys.receivesBetaUpdates)
        }
    }
}

struct SparkleUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    init?(infoDictionary: [String: Any]?) {
        guard
            let feedURLString = infoDictionary?.trimmedString(forKey: "SUFeedURL"),
            let feedURL = URL(string: feedURLString),
            feedURL.scheme != nil,
            let publicKey = infoDictionary?.trimmedString(forKey: "SUPublicEDKey")
        else {
            return nil
        }

        self.feedURL = feedURL
        self.publicKey = publicKey
    }
}

private extension Dictionary where Key == String, Value == Any {
    func trimmedString(forKey key: String) -> String? {
        guard let value = self[key] as? String else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

/// Returns the appcast channels the user is allowed to see. An empty set means
/// stable-only; `beta` additionally surfaces items tagged `<sparkle:channel>beta`.
private final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        userDefaults.bool(forKey: BeadazzlePreferenceKeys.receivesBetaUpdates) ? ["beta"] : []
    }
}

/// Drives the enabled state of the "Check for Updates…" menu item so it dims
/// while a check is already in flight.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
