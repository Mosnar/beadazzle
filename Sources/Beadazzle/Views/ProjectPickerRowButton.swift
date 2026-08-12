import SwiftUI

/// A trailing icon action on a picker row. Revealed on hover or focus so the resting row
/// stays quiet, while the row's keyboard shortcuts retain the same actions when hidden.
struct ProjectPickerRowButton: View {
    let systemImage: String
    let isVisible: Bool
    let isActive: Bool
    let help: String
    let accessibilityLabel: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(isActive ? .white.opacity(0.78) : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}
