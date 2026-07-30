import AppKit
import XCTest
@testable import Beadazzle

/// Focusing an `NSSearchField` makes the window's field editor the first
/// responder rather than the search field itself, so these drive real AppKit
/// focus to confirm the probe recognizes that indirection — ⌘F escalation
/// depends on it.
@MainActor
final class SearchFieldFocusProbeTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Programmatically created windows release themselves on close, which
        // over-releases under ARC and crashes the test process.
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
        }
        return window
    }

    func testFocusedSearchFieldIsDetectedThroughItsFieldEditor() throws {
        let window = makeWindow()
        let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(searchField)

        XCTAssertTrue(window.makeFirstResponder(searchField))

        // Sanity-check the indirection this probe exists to handle.
        XCTAssertFalse(window.firstResponder is NSSearchField)
        XCTAssertTrue(SearchFieldFocusProbe.isSearchField(window.firstResponder))
    }

    func testFocusedPlainTextFieldIsNotMistakenForTheSearchField() throws {
        let window = makeWindow()
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(textField)

        XCTAssertTrue(window.makeFirstResponder(textField))

        XCTAssertFalse(SearchFieldFocusProbe.isSearchField(window.firstResponder))
    }

    func testSearchFieldItselfIsDetected() {
        let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))

        XCTAssertTrue(SearchFieldFocusProbe.isSearchField(searchField))
    }

    func testUnfocusedWindowReportsNoSearchField() {
        let window = makeWindow()

        // A window with nothing focused reports itself as first responder.
        XCTAssertFalse(SearchFieldFocusProbe.isSearchField(window.firstResponder))
    }

    func testNilResponderIsNotASearchField() {
        XCTAssertFalse(SearchFieldFocusProbe.isSearchField(nil))
    }

    /// SwiftUI is free to back `.searchable` with a private type that isn't an
    /// `NSSearchField` subclass, so the name check has to catch it.
    func testASearchFieldLikeViewThatIsNotAnNSSearchFieldIsDetected() throws {
        let window = makeWindow()
        let field = PrivateLookingSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(field)

        XCTAssertTrue(window.makeFirstResponder(field))

        XCTAssertFalse(window.firstResponder is NSSearchField)
        XCTAssertTrue(SearchFieldFocusProbe.isSearchField(window.firstResponder))
    }

    func testAnUnrelatedViewIsNotMatchedByName() {
        let plain = NSView(frame: .zero)

        XCTAssertFalse(SearchFieldFocusProbe.isSearchField(plain))
    }
}

/// Stands in for a private SwiftUI search control: named like one, but not an
/// `NSSearchField` subclass.
private final class PrivateLookingSearchField: NSTextField {}
