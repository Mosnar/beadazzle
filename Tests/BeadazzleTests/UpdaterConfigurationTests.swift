import XCTest
@testable import Beadazzle

@MainActor
private final class MockSparkleUpdater: SparkleUpdating {
    var automaticallyChecksForUpdates: Bool
    private(set) var backgroundCheckCount = 0
    private(set) var resetCycleCount = 0

    init(automaticallyChecksForUpdates: Bool) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdatesInBackground() {
        backgroundCheckCount += 1
    }

    func resetUpdateCycleAfterShortDelay() {
        resetCycleCount += 1
    }
}

final class UpdaterConfigurationTests: XCTestCase {
    func testConfigurationRequiresFeedURLAndPublicKey() {
        XCTAssertNil(SparkleUpdateConfiguration(infoDictionary: nil))
        XCTAssertNil(SparkleUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://example.com/appcast.xml"
        ]))
        XCTAssertNil(SparkleUpdateConfiguration(infoDictionary: [
            "SUPublicEDKey": "public-key"
        ]))
    }

    func testConfigurationTrimsRequiredValues() throws {
        let configuration = try XCTUnwrap(SparkleUpdateConfiguration(infoDictionary: [
            "SUFeedURL": " https://example.com/appcast.xml ",
            "SUPublicEDKey": " public-key "
        ]))

        XCTAssertEqual(configuration.feedURL.absoluteString, "https://example.com/appcast.xml")
        XCTAssertEqual(configuration.publicKey, "public-key")
    }

    func testBlankConfigurationValuesAreUnavailable() {
        XCTAssertNil(SparkleUpdateConfiguration(infoDictionary: [
            "SUFeedURL": " ",
            "SUPublicEDKey": "public-key"
        ]))
        XCTAssertNil(SparkleUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "\n"
        ]))
    }

    @MainActor
    func testControllerDoesNotStartSparkleWithoutPublicKey() {
        let controller = UpdaterController(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            infoDictionary: [
                "SUFeedURL": "https://example.com/appcast.xml"
            ]
        )

        XCTAssertFalse(controller.isUpdateCheckingAvailable)
        XCTAssertNil(controller.updater)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)

        controller.automaticallyChecksForUpdates = true
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
    }

    @MainActor
    func testBetaUpdatePreferencePersistsThroughInjectedUserDefaults() {
        let suiteName = "UpdaterConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let controller = UpdaterController(userDefaults: defaults, infoDictionary: nil)
        XCTAssertFalse(controller.receivesBetaUpdates)

        controller.receivesBetaUpdates = true

        let reloadedController = UpdaterController(userDefaults: defaults, infoDictionary: nil)
        XCTAssertTrue(reloadedController.receivesBetaUpdates)
    }

    @MainActor
    func testOptedInControllerChecksOnceOnLaunch() {
        let updater = MockSparkleUpdater(automaticallyChecksForUpdates: true)

        let controller = UpdaterController(
            infoDictionary: validInfoDictionary,
            updaterOverride: updater
        )

        XCTAssertTrue(controller.isUpdateCheckingAvailable)
        XCTAssertEqual(updater.backgroundCheckCount, 1)
    }

    @MainActor
    func testOptedOutControllerDoesNotCheckOnLaunch() {
        let updater = MockSparkleUpdater(automaticallyChecksForUpdates: false)

        _ = UpdaterController(
            infoDictionary: validInfoDictionary,
            updaterOverride: updater
        )

        XCTAssertEqual(updater.backgroundCheckCount, 0)
    }

    @MainActor
    func testInvalidConfigurationDoesNotUseInjectedUpdater() {
        let updater = MockSparkleUpdater(automaticallyChecksForUpdates: true)

        let controller = UpdaterController(
            infoDictionary: nil,
            updaterOverride: updater
        )

        XCTAssertFalse(controller.isUpdateCheckingAvailable)
        XCTAssertEqual(updater.backgroundCheckCount, 0)
    }

    @MainActor
    func testBetaPreferenceChangeResetsUpdateCycle() {
        let suiteName = "UpdaterConfigurationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let updater = MockSparkleUpdater(automaticallyChecksForUpdates: false)
        let controller = UpdaterController(
            userDefaults: defaults,
            infoDictionary: validInfoDictionary,
            updaterOverride: updater
        )

        controller.receivesBetaUpdates = true
        controller.receivesBetaUpdates = true

        XCTAssertTrue(controller.receivesBetaUpdates)
        XCTAssertEqual(updater.resetCycleCount, 1)
    }

    private var validInfoDictionary: [String: Any] {
        [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "public-key"
        ]
    }
}
