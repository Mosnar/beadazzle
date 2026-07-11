import Foundation

/// Hardware key codes for AppKit `NSEvent.keyCode` handling, shared so views don't
/// scatter magic numbers.
enum KeyCode {
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
}
