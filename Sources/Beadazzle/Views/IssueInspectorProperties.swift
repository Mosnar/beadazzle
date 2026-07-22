import SwiftUI

struct IssueInspectorProperties: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft
    let includesStatus: Bool
    var typeOptions: [String]? = nil

    var body: some View {
        if includesStatus {
            InspectorOptionRow(
                title: "Status",
                systemImage: store.statusSymbol(for: draft.status),
                tint: store.statusColor(for: draft.status),
                options: store.statusOptions(including: draft.status),
                selected: $draft.status,
                numericShortcutStart: 1,
                displayValue: { $0 }
            )
            InspectorRowDivider()
        }

        InspectorOptionRow(
            title: "Type",
            systemImage: "tag",
            options: typeOptions ?? store.mutableTypeOptions(including: draft.issueType),
            selected: $draft.issueType,
            numericShortcutStart: 1,
            displayValue: { $0 }
        )
        InspectorRowDivider()

        InspectorOptionRow(
            title: "Priority",
            systemImage: "exclamationmark.triangle",
            tint: BeadVisualStyle.priorityColor(for: draft.priority),
            options: Array(0...4),
            selected: $draft.priority,
            numericShortcutStart: 0,
            displayValue: { "P\($0)" }
        )
    }
}

struct InspectorOptionRow<Option: Hashable>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let options: [Option]
    @Binding var selected: Option
    var numericShortcutStart: Int? = nil
    let displayValue: (Option) -> String

    init(
        title: String,
        systemImage: String,
        tint: Color = .secondary,
        options: [Option],
        selected: Binding<Option>,
        numericShortcutStart: Int? = nil,
        displayValue: @escaping (Option) -> String
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.options = options
        self._selected = selected
        self.numericShortcutStart = numericShortcutStart
        self.displayValue = displayValue
    }

    var body: some View {
        IssueMetadataOptionControl(
            title: title,
            systemImage: systemImage,
            tint: tint,
            options: options,
            selected: $selected,
            presentation: .inspectorRow,
            numericShortcutStart: numericShortcutStart,
            displayValue: displayValue
        )
    }
}

struct InspectorOptionItemRow: View {
    let title: String
    let badge: String?
    let shortcut: InspectorOptionShortcut?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    init(
        title: String,
        badge: String? = nil,
        shortcut: InspectorOptionShortcut? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.badge = badge
        self.shortcut = shortcut
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingLabel = badge ?? shortcut?.label {
                    Text(trailingLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background((isHovered || isSelected) ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .modifier(InspectorOptionKeyboardShortcutModifier(shortcut: shortcut))
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(shortcut.map { "Keyboard shortcut \($0.label)" } ?? "")
    }
}

private struct InspectorOptionKeyboardShortcutModifier: ViewModifier {
    let shortcut: InspectorOptionShortcut?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.keyEquivalent, modifiers: [])
        } else {
            content
        }
    }
}
