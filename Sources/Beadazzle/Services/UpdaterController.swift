import Combine
import Foundation
import Sparkle

@MainActor
protocol SparkleUpdating: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdatesInBackground()
    func resetUpdateCycleAfterShortDelay()
}

extension SPUUpdater: SparkleUpdating {}

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
    private let updaterClient: (any SparkleUpdating)?
    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        updaterOverride: (any SparkleUpdating)? = nil
    ) {
        self.userDefaults = userDefaults

        if SparkleUpdateConfiguration(infoDictionary: infoDictionary) != nil {
            if let updaterOverride {
                self.channelDelegate = nil
                self.standardUpdaterController = nil
                self.updaterClient = updaterOverride
            } else {
                let channelDelegate = UpdaterChannelDelegate(userDefaults: userDefaults)
                let standardUpdaterController = SPUStandardUpdaterController(
                    startingUpdater: true,
                    updaterDelegate: channelDelegate,
                    userDriverDelegate: nil
                )
                self.channelDelegate = channelDelegate
                self.standardUpdaterController = standardUpdaterController
                self.updaterClient = standardUpdaterController.updater
            }
        } else {
            self.channelDelegate = nil
            self.standardUpdaterController = nil
            self.updaterClient = nil
        }

        // Sparkle's scheduler does not guarantee a check on every launch. Its
        // documented launch-check path is an immediate background check after
        // startup, gated by the user's automatic-check preference.
        if updaterClient?.automaticallyChecksForUpdates == true {
            updaterClient?.checkForUpdatesInBackground()
        }
    }

    var updater: SPUUpdater? { standardUpdaterController?.updater }

    var isUpdateCheckingAvailable: Bool { updaterClient != nil }

    /// Bound by the Updates settings pane. Sparkle persists this itself.
    var automaticallyChecksForUpdates: Bool {
        get { updaterClient?.automaticallyChecksForUpdates ?? false }
        set {
            guard let updaterClient else { return }
            objectWillChange.send()
            updaterClient.automaticallyChecksForUpdates = newValue
        }
    }

    /// Opts the app into Sparkle's `beta` appcast channel.
    var receivesBetaUpdates: Bool {
        get { userDefaults.bool(forKey: BeadazzlePreferenceKeys.receivesBetaUpdates) }
        set {
            guard newValue != receivesBetaUpdates else { return }
            objectWillChange.send()
            userDefaults.set(newValue, forKey: BeadazzlePreferenceKeys.receivesBetaUpdates)
            updaterClient?.resetUpdateCycleAfterShortDelay()
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
