import XCTest
@testable import Beadazzle

final class InspectorOptionShortcutTests: XCTestCase {
    func testNumericShortcutsUseOneBasedLabelsForFirstNineItems() {
        XCTAssertEqual(InspectorOptionShortcut.numeric(at: 0)?.label, "1")
        XCTAssertEqual(InspectorOptionShortcut.numeric(at: 4)?.label, "5")
        XCTAssertEqual(InspectorOptionShortcut.numeric(at: 8)?.label, "9")
    }

    func testNumericShortcutsIgnoreMissingOrOutOfRangeItems() {
        XCTAssertNil(InspectorOptionShortcut.numeric(at: nil))
        XCTAssertNil(InspectorOptionShortcut.numeric(at: -1))
        XCTAssertNil(InspectorOptionShortcut.numeric(at: 9))
    }

    func testNumericShortcutsCanMatchZeroBasedPriorityValues() {
        XCTAssertEqual(InspectorOptionShortcut.numeric(at: 0, startingAt: 0)?.label, "0")
        XCTAssertEqual(InspectorOptionShortcut.numeric(at: 4, startingAt: 0)?.label, "4")
        XCTAssertEqual(InspectorOptionShortcut.numeric(at: 9, startingAt: 0)?.label, "9")
        XCTAssertNil(InspectorOptionShortcut.numeric(at: 10, startingAt: 0))
    }
}
