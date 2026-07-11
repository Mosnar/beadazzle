import XCTest
@testable import Beadazzle

final class NaturalStringOrderingTests: XCTestCase {
    func testCaseInsensitive() {
        XCTAssertEqual("Alpha".naturalCompare("alpha"), .orderedSame)
        XCTAssertEqual("alpha".naturalCompare("Beta"), .orderedAscending)
        XCTAssertEqual("Zebra".naturalCompare("apple"), .orderedDescending)
    }

    func testNumericRunsCompareAsNumbers() {
        XCTAssertEqual("issue-2".naturalCompare("issue-10"), .orderedAscending)
        XCTAssertEqual("issue-10".naturalCompare("issue-2"), .orderedDescending)
        XCTAssertEqual("issue-007".naturalCompare("issue-7"), .orderedSame)
        XCTAssertEqual("v1.9".naturalCompare("v1.10"), .orderedAscending)
    }

    func testNumericTieFallsThroughToSuffix() {
        XCTAssertEqual("issue-2a".naturalCompare("issue-2b"), .orderedAscending)
        XCTAssertEqual("issue-02b".naturalCompare("issue-2a"), .orderedDescending)
    }

    func testPrefixOrdering() {
        XCTAssertEqual("abc".naturalCompare("abcd"), .orderedAscending)
        XCTAssertEqual("abcd".naturalCompare("abc"), .orderedDescending)
        XCTAssertEqual("".naturalCompare(""), .orderedSame)
        XCTAssertEqual("".naturalCompare("a"), .orderedAscending)
    }

    func testMixedDigitAndText() {
        XCTAssertEqual("2 apples".naturalCompare("10 apples"), .orderedAscending)
        XCTAssertEqual("beadazzle-cuc".naturalCompare("beadazzle-cud"), .orderedAscending)
    }

    func testNonASCIIFolds() {
        XCTAssertEqual("Éclair".naturalCompare("éclair"), .orderedSame)
    }
}
