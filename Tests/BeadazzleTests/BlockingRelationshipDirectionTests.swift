import XCTest
@testable import Beadazzle

final class BlockingRelationshipDirectionTests: XCTestCase {
    func testDirectionsShareTitlesAndSymbolsAcrossRelationshipSurfaces() {
        XCTAssertEqual(BlockingRelationshipDirection.blockedBy.title, "Blocked by")
        XCTAssertEqual(
            BlockingRelationshipDirection.blockedBy.systemImage,
            "arrow.down.right.and.arrow.up.left"
        )
        XCTAssertEqual(BlockingRelationshipDirection.blocking.title, "Blocking")
        XCTAssertEqual(BlockingRelationshipDirection.blocking.systemImage, "arrow.up.forward")
    }

    func testSummariesUseDirectionalSingularAndPluralLanguage() {
        XCTAssertEqual(
            BlockingRelationshipDirection.blockedBy.summary(count: 1),
            "Blocked by 1 active bead"
        )
        XCTAssertEqual(
            BlockingRelationshipDirection.blockedBy.summary(count: 2),
            "Blocked by 2 active beads"
        )
        XCTAssertEqual(
            BlockingRelationshipDirection.blocking.summary(count: 1),
            "Blocking 1 active bead"
        )
        XCTAssertEqual(
            BlockingRelationshipDirection.blocking.summary(count: 2),
            "Blocking 2 active beads"
        )
    }
}
