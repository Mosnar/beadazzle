import SwiftUI

struct BlockingRelationshipCountPopover: View {
    let direction: BlockingRelationshipDirection
    let items: [BlockingRelationshipItem]
    let openIssue: (String) -> Void

    var body: some View {
        HoverPersistentPopover(
            arrowEdge: .bottom,
            fillsAvailableWidth: false
        ) { _ in
            Label(items.count.formatted(), systemImage: direction.systemImage)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        } interactivePreview: {
            BlockingRelationshipPreview(
                direction: direction,
                items: items,
                openIssue: openIssue
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(direction.title)
        .accessibilityValue(direction.summary(count: items.count))
        .accessibilityHint(direction.accessibilityHint)
    }
}

private struct BlockingRelationshipPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsKeyboardFocus = false

    let direction: BlockingRelationshipDirection
    let items: [BlockingRelationshipItem]
    let openIssue: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(direction.summary(count: items.count), systemImage: direction.systemImage)
                .font(.headline)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        BlockingRelationshipPreviewRow(
                            item: item,
                            showsKeyboardFocus: showsKeyboardFocus
                        ) {
                            dismiss()
                            openIssue(item.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .onKeyPress(.tab) {
            showsKeyboardFocus = true
            return .ignored
        }
        .onKeyPress(.upArrow) {
            showsKeyboardFocus = true
            return .ignored
        }
        .onKeyPress(.downArrow) {
            showsKeyboardFocus = true
            return .ignored
        }
    }
}

private struct BlockingRelationshipPreviewRow: View {
    let item: BlockingRelationshipItem
    let showsKeyboardFocus: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: BeadVisualStyle.symbol(forCategory: item.statusCategory))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(BeadVisualStyle.color(forCategory: item.statusCategory))
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(item.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.issue.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .background(
                isHovered || (showsKeyboardFocus && isFocused) ? InspectorChrome.rowHoverFill : .clear,
                in: RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(item.issue.title), \(item.id)")
        .accessibilityValue("Status: \(item.issue.status)")
        .accessibilityHint("Opens the bead")
    }
}
