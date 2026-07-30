import XCTest
@testable import Beadazzle

final class AboutBeadazzleInfoTests: XCTestCase {
    func testVersionDescriptionIncludesVersionAndBuild() {
        let info = AboutBeadazzleInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": "123",
        ])

        XCTAssertEqual(info.versionDescription, "Version 1.4.0 (123)")
    }

    func testVersionDescriptionOmitsMissingBuild() {
        let info = AboutBeadazzleInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.4.0 ",
            "CFBundleVersion": " ",
        ])

        XCTAssertEqual(info.versionDescription, "Version 1.4.0")
    }

    func testVersionDescriptionFallsBackForMissingVersion() {
        let info = AboutBeadazzleInfo(infoDictionary: [
            "CFBundleVersion": "123",
        ])

        XCTAssertEqual(info.versionDescription, "Development build")
    }

    func testAuthorAndSupportDestinations() {
        XCTAssertEqual(AboutBeadazzleInfo.author, "Ransom Roberson")
        XCTAssertEqual(AboutBeadazzleInfo.emailAddress, "beadazzle@ransom.lol")
        XCTAssertEqual(
            AboutBeadazzleInfo.repositoryURL.absoluteString,
            "https://github.com/Mosnar/beadazzle"
        )
        XCTAssertEqual(
            AboutBeadazzleInfo.issuesURL.absoluteString,
            "https://github.com/Mosnar/beadazzle/issues"
        )
    }

    func testDisclosureMetadataMatchesBundledFilenames() {
        XCTAssertEqual(AboutDisclosure.acknowledgments.title, "Acknowledgments")
        XCTAssertEqual(AboutDisclosure.acknowledgments.resourceName, "THIRD_PARTY_NOTICES")
        XCTAssertEqual(AboutDisclosure.acknowledgments.resourceExtension, "md")
        XCTAssertEqual(AboutDisclosure.license.title, "License")
        XCTAssertEqual(AboutDisclosure.license.resourceName, "LICENSE")
        XCTAssertNil(AboutDisclosure.license.resourceExtension)
    }

    func testDisclosureDocumentLoadsUTF8Content() throws {
        let resourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "Bundled notice".write(to: resourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: resourceURL) }

        let document = AboutDisclosureDocument(
            disclosure: .acknowledgments,
            resourceURL: resourceURL
        )

        XCTAssertEqual(document.contents, .loaded("Bundled notice"))
    }

    func testSwiftPMDisclosureResourcesMatchRepositoryDocuments() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for disclosure in AboutDisclosure.allCases {
            var repositoryDocumentURL = repositoryRoot
                .appendingPathComponent(disclosure.resourceName)
            if let resourceExtension = disclosure.resourceExtension {
                repositoryDocumentURL.appendPathExtension(resourceExtension)
            }
            let expectedContents = try String(
                contentsOf: repositoryDocumentURL,
                encoding: .utf8
            )
            let document = AboutDisclosureDocument(disclosure: disclosure)

            XCTAssertEqual(
                document.contents,
                .loaded(expectedContents),
                "\(disclosure.title) should load from SwiftPM resources and match the repository copy."
            )
        }
    }

    func testDisclosureDocumentReportsMissingResource() {
        let document = AboutDisclosureDocument(
            disclosure: .license,
            resourceURL: nil
        )

        XCTAssertEqual(
            document.contents,
            .unavailable("License could not be found in this copy of Beadazzle.")
        )
    }
}
