import SwiftUI

struct IssueMetadataControlLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    let presentation: IssueMetadataControlPresentation
    let showsChevron: Bool
    let isHighlighted: Bool

    var body: some View {
        switch presentation {
        case .inspectorRow:
            InspectorRowLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                value: value,
                showsChevron: showsChevron,
                isHighlighted: isHighlighted
            )
        case .ribbonChip:
            IssueMetadataRibbonChipLabel(
                systemImage: systemImage,
                tint: tint,
                value: value,
                showsChevron: showsChevron,
                isHighlighted: isHighlighted
            )
        }
    }
}

struct IssueMetadataRibbonChipLabel: View {
    let systemImage: String
    let tint: Color
    let value: String
    let showsChevron: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 16, alignment: .center)
                .accessibilityHidden(true)

            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .padding(.leading, 9)
        .padding(.trailing, showsChevron ? 8 : 9)
        .padding(.vertical, 4)
        .frame(minHeight: InspectorChrome.ribbonChipMinHeight)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(RoundedRectangle(cornerRadius: InspectorChrome.ribbonChipCornerRadius, style: .continuous))
        .background(
            isHighlighted ? InspectorChrome.rowHoverFill : InspectorChrome.ribbonChipFill,
            in: RoundedRectangle(cornerRadius: InspectorChrome.ribbonChipCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: InspectorChrome.ribbonChipCornerRadius, style: .continuous)
                .stroke(InspectorChrome.ribbonChipStroke, lineWidth: 1)
        }
    }
}
