import Foundation
import XCTest
@testable import Beadazzle

final class IssueReferenceLinkingTests: XCTestCase {
    func testMatcherUsesMaximalASCIITokensAndExactCaseSensitiveMembership() {
        let matcher = IssueReferenceMatcher(issueIDs: ["bd-1", "proj.alpha-2", "BD-3"])
        let text = "xbd-1 bd-1x (bd-1), proj.alpha-2 bd-3 BD-3"

        XCTAssertEqual(
            matcher.matches(in: text).map(\.issueID),
            ["bd-1", "proj.alpha-2", "BD-3"]
        )
    }

    func testMatcherHonorsRequestedUTF16Range() {
        let matcher = IssueReferenceMatcher(issueIDs: ["bd-1", "bd-2"])
        let text = "😀 bd-1\nbd-2"
        let nsText = text as NSString
        let firstLine = nsText.lineRange(for: NSRange(location: 0, length: 0))

        XCTAssertEqual(matcher.matches(in: text, range: firstLine).map(\.issueID), ["bd-1"])
    }

    func testMatcherSupportsKnownSeparatorlessIDsWithoutMatchingPartials() {
        let matcher = IssueReferenceMatcher(issueIDs: ["ABC"])

        XCTAssertEqual(matcher.matches(in: "ABC XABC ABCX").map(\.issueID), ["ABC"])
    }

    func testBeadURLRoundTripsAndRejectsMalformedShapes() throws {
        let id = "proj.alpha-2"
        let url = try XCTUnwrap(BeadIssueURL.url(for: id))

        XCTAssertEqual(url.absoluteString, "beads://bead/proj.alpha-2")
        XCTAssertEqual(BeadIssueURL.issueID(from: url), id)
        XCTAssertNil(BeadIssueURL.issueID(from: try XCTUnwrap(URL(string: "beads://issue/\(id)"))))
        XCTAssertNil(BeadIssueURL.issueID(from: try XCTUnwrap(URL(string: "beads://bead/a/b"))))
        XCTAssertNil(BeadIssueURL.issueID(from: try XCTUnwrap(URL(string: "beads://bead/a%2Fb"))))
        XCTAssertNil(BeadIssueURL.issueID(from: try XCTUnwrap(URL(string: "beads://bead/\(id)?x=1"))))
    }

    func testCommentAttributedStringLinksOnlyKnownIssueIDs() {
        let lookup = IssueReferenceLookup(issueIDs: ["bd-1"], revision: 7)
        let attributed = IssueReferenceAttributedStringBuilder.make(
            text: "See bd-1, not bd-2.",
            lookup: lookup
        )
        let links = attributed.runs.compactMap(\.link)

        XCTAssertEqual(links.map(\.absoluteString), ["beads://bead/bd-1"])
        XCTAssertEqual(lookup.fingerprint() as? Int, 7)
    }

    func testMatcherPerformanceDoesNotScaleWithKnownIssueCount() throws {
        guard ProcessInfo.processInfo.environment["BEADAZZLE_LINK_BENCH"] == "1" else {
            throw XCTSkip("Set BEADAZZLE_LINK_BENCH=1 to run the automatic-link performance gate")
        }
        #if DEBUG
        throw XCTSkip("Thresholds are calibrated for optimized builds — run with `swift test -c release`")
        #else
        let issueIDs = Set((0..<25_000).map { "bd-\($0)" })
        let matcher = IssueReferenceMatcher(issueIDs: issueIDs)
        let smallText = makeText(byteCount: 8 * 1_024)
        let largeText = makeText(byteCount: 100 * 1_024)
        let smallP95 = p95Milliseconds(iterations: 40) {
            _ = matcher.matches(in: smallText)
        }
        let largeP95 = p95Milliseconds(iterations: 40) {
            _ = matcher.matches(in: largeText)
        }

        XCTAssertLessThanOrEqual(smallP95, 2.0, "8 KB p95 was \(smallP95) ms")
        XCTAssertLessThanOrEqual(largeP95, 8.0, "100 KB p95 was \(largeP95) ms")
        #endif
    }

    private func makeText(byteCount: Int) -> String {
        let fragment = "plain words bd-42 and proj.unknown-1; "
        return String(repeating: fragment, count: byteCount / fragment.utf8.count + 1)
            .prefix(byteCount)
            .description
    }

    private func p95Milliseconds(iterations: Int, operation: () -> Void) -> Double {
        operation()
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = ProcessInfo.processInfo.systemUptime
            operation()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        samples.sort()
        return samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    }
}
