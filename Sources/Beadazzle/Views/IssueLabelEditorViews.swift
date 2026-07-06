import SwiftUI

struct InspectorLabelsRow: View {
    @Binding var draft: IssueDraft
    let availableLabels: [String]

    var body: some View {
        IssueMetadataLabelsControl(
            draft: $draft,
            availableLabels: availableLabels,
            presentation: .inspectorRow
        )
    }
}

struct LabelEditorPopover: View {
    @Binding var labels: [String]
    let availableLabels: [String]
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var candidateLabels: [String] {
        uniqueSortedLabels(availableLabels + labels)
    }

    private var visibleLabels: [String] {
        guard !trimmedQuery.isEmpty else { return candidateLabels }
        return candidateLabels.filter { $0.localizedStandardContains(trimmedQuery) }
    }

    private var canCreateQuery: Bool {
        guard !trimmedQuery.isEmpty else { return false }
        return !candidateLabels.contains { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
    }

    private var suggestionRowCount: Int {
        if visibleLabels.isEmpty && !canCreateQuery {
            return 1
        }
        return visibleLabels.count + (canCreateQuery ? 1 : 0)
    }

    private var suggestionListHeight: CGFloat {
        let visibleRows = min(max(suggestionRowCount, 1), 5)
        return CGFloat(visibleRows * 34 + max(visibleRows - 1, 0) * 2)
    }

    private var selectedLabelsHeight: CGFloat {
        let rows = min(max((labels.count + 1) / 2, 1), 3)
        return CGFloat(rows * 24 + max(rows - 1, 0) * 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Labels")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LabelSearchField(text: $query)
                .onSubmit(addQueryLabels)

            if !labels.isEmpty {
                ScrollView {
                    LabelChipFlow(spacing: 6) {
                        ForEach(labels, id: \.self) { label in
                            EditableLabelChip(label: label) {
                                remove(label)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: selectedLabelsHeight)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleLabels.isEmpty && !canCreateQuery {
                        Text("No labels")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                    } else {
                        ForEach(visibleLabels, id: \.self) { label in
                            LabelSuggestionRow(
                                label: label,
                                isSelected: labels.contains(label)
                            ) {
                                toggle(label)
                            }
                        }
                    }

                    if canCreateQuery {
                        LabelCreateRow(query: trimmedQuery, action: addQueryLabels)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: suggestionListHeight)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private func addQueryLabels() {
        let nextLabels = IssueDraft.normalizedLabels(query)
        guard !nextLabels.isEmpty else { return }
        for label in nextLabels {
            add(label)
        }
        query = ""
    }

    private func toggle(_ label: String) {
        if labels.contains(label) {
            remove(label)
        } else {
            add(label)
        }
    }

    private func add(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !labels.contains(trimmed) else { return }
        labels.append(trimmed)
        labels = uniqueLabels(labels)
    }

    private func remove(_ label: String) {
        labels.removeAll { $0 == label }
    }

    private func uniqueLabels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for label in labels {
            guard !seen.contains(label) else { continue }
            seen.insert(label)
            result.append(label)
        }
        return result
    }

    private func uniqueSortedLabels(_ labels: [String]) -> [String] {
        uniqueLabels(labels)
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }
}

struct LabelChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let rows = rows(in: availableWidth, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + row.height + (row.index == rows.startIndex ? 0 : spacing)
        }
        let width = availableWidth.isFinite ? availableWidth : rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(in: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(in availableWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentItems: [Item] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let additionalWidth = currentItems.isEmpty ? size.width : size.width + spacing

            if !currentItems.isEmpty, currentWidth + additionalWidth > availableWidth {
                rows.append(Row(index: rows.count, items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            currentItems.append(Item(subview: subview, size: size))
            currentWidth += currentItems.count == 1 ? size.width : size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(Row(index: rows.count, items: currentItems, width: currentWidth, height: currentHeight))
        }

        return rows
    }

    private struct Row {
        let index: Int
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }
}

struct LabelSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search or create", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(InspectorChrome.searchFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(InspectorChrome.sectionStroke, lineWidth: 1)
        }
        .task {
            isFocused = true
        }
    }
}

struct EditableLabelChip: View {
    let label: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(label)")
            .accessibilityLabel("Remove \(label)")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.35), in: Capsule())
    }
}

struct LabelSuggestionRow: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)

                Text(label)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background((isHovered || isSelected) ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct LabelCreateRow: View {
    let query: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Create \"\(query)\"", systemImage: "plus")
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(isHovered ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Create \(query)")
    }
}
