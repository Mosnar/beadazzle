import AppKit
import SwiftUI

enum BeadPickerChrome {
    static let surfaceCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 8
    static let controlCornerRadius: CGFloat = 8
    static let rowHorizontalInset: CGFloat = 8
    static let quickCreateFallbackHeight: CGFloat = 134

    static func quickCreateAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.88)
    }

    static var dividerFill: Color {
        Color(nsColor: .separatorColor).opacity(0.24)
    }

    static var surfaceStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.38)
    }

    static var controlFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.44)
    }

    static var controlStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.28)
    }

    static var groupFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.32)
    }

    static var rowHoverFill: Color {
        Color.primary.opacity(0.06)
    }

    static var selectedRowFill: Color {
        Color(nsColor: .selectedContentBackgroundColor).opacity(0.82)
    }
}

struct BeadPickerDivider: View {
    var body: some View {
        Rectangle()
            .fill(BeadPickerChrome.dividerFill)
            .frame(height: 1)
    }
}

private struct BeadPickerQuickCreateHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BeadPickerCollapsible<Content: View>: View {
    let isExpanded: Bool
    let reduceMotion: Bool
    private let content: Content
    @State private var measuredHeight = BeadPickerChrome.quickCreateFallbackHeight

    init(isExpanded: Bool, reduceMotion: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.reduceMotion = reduceMotion
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(y: reduceMotion || isExpanded ? 1 : 0.985, anchor: .top)
                .offset(y: reduceMotion || isExpanded ? 0 : -4)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BeadPickerQuickCreateHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: isExpanded ? measuredHeight : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .onPreferenceChange(BeadPickerQuickCreateHeightKey.self) { height in
            guard height > 0, abs(measuredHeight - height) > 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                measuredHeight = height
            }
        }
        .animation(BeadPickerChrome.quickCreateAnimation(reduceMotion: reduceMotion), value: isExpanded)
    }
}

private struct BeadPickerPopoverSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
                    .clipShape(RoundedRectangle(cornerRadius: BeadPickerChrome.surfaceCornerRadius, style: .continuous))
                    .glassEffect(.regular, in: .rect(cornerRadius: BeadPickerChrome.surfaceCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: BeadPickerChrome.surfaceCornerRadius, style: .continuous)
                            .stroke(BeadPickerChrome.surfaceStroke, lineWidth: 1)
                    }
            }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: BeadPickerChrome.surfaceCornerRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: BeadPickerChrome.surfaceCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BeadPickerChrome.surfaceCornerRadius, style: .continuous)
                        .stroke(BeadPickerChrome.surfaceStroke, lineWidth: 1)
                }
        }
    }
}

extension View {
    func beadPickerPopoverSurface() -> some View {
        modifier(BeadPickerPopoverSurface())
    }
}
