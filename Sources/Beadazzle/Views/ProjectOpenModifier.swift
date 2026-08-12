import AppKit

/// Holding ⌥ while activating an open action sends the project to a new window, matching
/// the macOS convention of Option meaning "somewhere else". SwiftUI button actions carry
/// no event, so the flags are read at activation time.
enum ProjectOpenModifier {
    static var destination: BeadProjectOpenDestination {
        NSEvent.modifierFlags.contains(.option) ? .newWindow : .preferred
    }
}
