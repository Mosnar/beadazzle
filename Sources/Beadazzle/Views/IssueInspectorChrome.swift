import SwiftUI

struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.none)
                .padding(.horizontal, 12)
                .padding(.top, 11)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(InspectorChrome.sectionFill, in: RoundedRectangle(cornerRadius: InspectorChrome.sectionCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: InspectorChrome.sectionCornerRadius, style: .continuous)
                .stroke(InspectorChrome.sectionStroke, lineWidth: 1)
        }
    }
}

struct InspectorValueRow: View {
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        InspectorRowLabel(
            title: title,
            systemImage: systemImage,
            tint: .secondary,
            value: value,
            showsChevron: false,
            isHighlighted: false
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct InspectorRowLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    let showsChevron: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 52, alignment: .trailing)
                .layoutPriority(1)

            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.horizontal, InspectorChrome.rowHorizontalPadding)
        .frame(minHeight: InspectorChrome.rowHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
        .background(isHighlighted ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
    }
}

struct InspectorRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(InspectorChrome.dividerFill)
            .frame(height: 1)
            .padding(.leading, InspectorChrome.rowHorizontalPadding + 26)
    }
}

enum InspectorChrome {
    static let sectionCornerRadius: CGFloat = 10
    static let rowCornerRadius: CGFloat = 7
    static let rowHeight: CGFloat = 38
    static let rowHorizontalPadding: CGFloat = 9
    static let ribbonChipCornerRadius: CGFloat = 9
    static let ribbonChipMinHeight: CGFloat = 30

    static var sectionFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    static var sectionStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.42)
    }

    static var dividerFill: Color {
        Color(nsColor: .separatorColor).opacity(0.42)
    }

    static var rowHoverFill: Color {
        Color.primary.opacity(0.065)
    }

    static var searchFill: Color {
        Color(nsColor: .textBackgroundColor).opacity(0.72)
    }

    static var ribbonFill: Color {
        Color(nsColor: .windowBackgroundColor).opacity(0.52)
    }

    static var ribbonChipFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    static var ribbonChipStroke: Color {
        Color(nsColor: .separatorColor).opacity(0.36)
    }
}
