import SwiftUI

struct DetailToolbarActionPresentationState: Equatable {
    var isHovered = false
    var isPressed = false
    var isFocused = false

    var isHighlighted: Bool {
        isHovered || isPressed || isFocused
    }

    var backgroundOpacity: Double {
        if isPressed {
            return 0.20
        }
        return isHighlighted ? 0.12 : 0
    }
}

enum DetailToolbarActionMetrics {
    static let width: CGFloat = 28
    static let height: CGFloat = 24
    static let cornerRadius: CGFloat = 7
}

struct DetailToolbarActionLabel: View {
    var body: some View {
        Color.clear
            .frame(
                width: DetailToolbarActionMetrics.width,
                height: DetailToolbarActionMetrics.height
            )
    }
}

struct DetailToolbarButtonStyle: ButtonStyle {
    let systemImage: String
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        DetailToolbarButtonControl(
            label: configuration.label,
            systemImage: systemImage,
            isPressed: configuration.isPressed,
            isFocused: isFocused
        )
    }
}

private struct DetailToolbarButtonControl<Label: View>: View {
    let label: Label
    let systemImage: String
    let isPressed: Bool
    let isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        let presentation = DetailToolbarActionPresentationState(
            isHovered: isHovered,
            isPressed: isPressed,
            isFocused: isFocused
        )

        ZStack {
            label

            DetailToolbarActionChrome(
                systemImage: systemImage,
                presentation: presentation,
                isFocused: isFocused
            )
            .allowsHitTesting(false)
        }
        .frame(
            width: DetailToolbarActionMetrics.width,
            height: DetailToolbarActionMetrics.height
        )
        .contentShape(
            RoundedRectangle(cornerRadius: DetailToolbarActionMetrics.cornerRadius)
        )
        .onHover { isHovered = $0 }
    }
}

private struct DetailToolbarActionChrome: View {
    let systemImage: String
    let presentation: DetailToolbarActionPresentationState
    let isFocused: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(presentation.isHighlighted ? Color.white : Color.secondary)
            .frame(
                width: DetailToolbarActionMetrics.width,
                height: DetailToolbarActionMetrics.height
            )
            .background {
                if presentation.isHighlighted {
                    RoundedRectangle(cornerRadius: DetailToolbarActionMetrics.cornerRadius)
                        .fill(Color.white.opacity(presentation.backgroundOpacity))
                }
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: DetailToolbarActionMetrics.cornerRadius)
                        .stroke(.tint.opacity(0.75), lineWidth: 1)
                }
            }
    }
}
