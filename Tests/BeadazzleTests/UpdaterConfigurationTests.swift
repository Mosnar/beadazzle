import XCTest
@testable import Beadazzle

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
}
