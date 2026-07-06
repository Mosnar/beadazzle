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
@MainActor
final class UpdaterController: ObservableObject {
    let standardUpdaterController: SPUStandardUpdaterController
    private let channelDelegate: UpdaterChannelDelegate
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let channelDelegate = UpdaterChannelDelegate(userDefaults: userDefaults)
        self.channelDelegate = channelDelegate
        // startingUpdater: true begins scheduled background checks immediately.
        self.standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channelDelegate,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { standardUpdaterController.updater }

    /// Bound by the Updates settings pane. Sparkle persists this itself.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
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
