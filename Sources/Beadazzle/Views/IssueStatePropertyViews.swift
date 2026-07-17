import SwiftUI

/// Inspector rows for the state dimensions pinned in Project Settings. Values
/// are written through `bd set-state` so every change also records an event
/// (with an optional reason) in the bead's activity history — never as a plain
/// label edit.
struct InspectorStatePropertyRows: View {
    let issue: BeadIssue
    let dimensions: [String]

    var body: some View {
        ForEach(dimensions, id: \.self) { dimension in
            InspectorStatePropertyRowGroup(
                issue: issue,
                dimension: dimension,
                showsDivider: dimension != dimensions.last
            )
        }
    }
}

private struct InspectorStatePropertyRowGroup: View {
    let issue: BeadIssue
    let dimension: String
    let showsDivider: Bool

    var body: some View {
        InspectorStateDimensionRow(issue: issue, dimension: dimension)
        if showsDivider {
            InspectorRowDivider()
        }
    }
}

struct InspectorStateDimensionRow: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    let dimension: String
    @State private var isPresented = false
    @State private var isHovered = false

    private var currentValue: String? {
        BeadStateLabel.value(of: dimension, in: issue.labels)
    }

    var body: some View {
        let displayName = store.stateDimensionDisplayName(for: dimension)
        let currentPresentation = currentValue.map {
            store.stateValuePresentation(for: $0, in: dimension)
        }

        Button {
            isPresented.toggle()
        } label: {
            InspectorRowLabel(
                title: displayName,
                systemImage: "slider.horizontal.3",
                tint: .secondary,
                value: currentPresentation?.displayName ?? "None",
                showsChevron: true,
                isHighlighted: isHovered || isPresented
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Set \(dimension); the change is recorded in Activity")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            let catalog = store.stateValueCatalog(for: dimension)
            StateValuePickerPopover(
                displayName: displayName,
                currentValue: currentValue,
                currentPresentation: currentPresentation,
                catalog: catalog
            ) { value, reason in
                isPresented = false
                Task {
                    if let value {
                        await store.setState(
                            issueID: issue.id,
                            dimension: dimension,
                            value: value,
                            reason: reason
                        )
                    } else {
                        await store.clearState(
                            issueID: issue.id,
                            dimension: dimension,
                            reason: reason
                        )
                    }
                }
            }
        }
        .accessibilityLabel(displayName)
        .accessibilityValue(currentPresentation?.displayName ?? "None")
        .accessibilityHint("Opens the state value picker")
    }
}

struct StateValuePickerPopover: View {
    let displayName: String
    let currentValue: String?
    private let candidateValues: [BeadStateValuePresentation]
    private let unavailableValues: [BeadStateValuePresentation]
    let commit: (String?, String?) -> Void
    @State private var query = ""
    @State private var reason = ""

    init(
        displayName: String,
        currentValue: String?,
        currentPresentation: BeadStateValuePresentation?,
        catalog: BeadStateValueCatalog,
        commit: @escaping (String?, String?) -> Void
    ) {
        self.displayName = displayName
        self.currentValue = currentValue
        var candidates = catalog.active
        var unavailable = catalog.archived
        if let currentPresentation,
           !candidates.contains(where: { $0.value == currentPresentation.value }) {
            candidates.insert(currentPresentation, at: 0)
            unavailable.removeAll { $0.value == currentPresentation.value }
        }
        candidateValues = candidates
        unavailableValues = unavailable
        self.commit = commit
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let suggestions = suggestions(for: trimmedQuery)

        VStack(alignment: .leading, spacing: 12) {
            Text(displayName)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LabelSearchField(text: $query)
                .onSubmit(commitQuery)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if suggestions.showsClearValue {
                        InspectorOptionItemRow(title: "None", isSelected: false) {
                            commit(nil, normalizedReason)
                        }
                    }

                    if suggestions.visibleValues.isEmpty
                        && suggestions.creatableValue == nil
                        && !suggestions.showsClearValue {
                        Text(emptyMessage(for: suggestions))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                    } else {
                        ForEach(suggestions.visibleValues) { value in
                            InspectorOptionItemRow(
                                title: value.displayName,
                                badge: value.isArchived ? "Archived" : nil,
                                isSelected: value.value == currentValue
                            ) {
                                guard value.value != currentValue else { return }
                                commit(value.value, normalizedReason)
                            }
                        }
                    }

                    if let creatableQueryValue = suggestions.creatableValue {
                        StateValueCreateRow(value: creatableQueryValue, action: commitQuery)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: suggestions.listHeight)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Reason (optional)", text: $reason)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(InspectorChrome.searchFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(InspectorChrome.sectionStroke, lineWidth: 1)
                    }

                Text("Recorded in the bead's activity history.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var normalizedReason: String? {
        reason.nilIfBlank
    }

    private func suggestions(for query: String) -> StateValueSuggestions {
        let visibleValues = query.isEmpty
            ? candidateValues
            : candidateValues.filter {
                $0.displayName.localizedStandardContains(query)
                    || $0.value.localizedStandardContains(query)
            }
        let queryMatch = BeadStateValuePickerPolicy.match(
            query: query,
            in: candidateValues,
            followedBy: unavailableValues
        )
        let archivedMatch: BeadStateValuePresentation?
        if case let .unique(value) = queryMatch,
           !isCandidate(value) {
            archivedMatch = value
        } else {
            archivedMatch = nil
        }
        let showsClearValue = currentValue != nil
            && (query.isEmpty || "None".localizedStandardContains(query))
        let queryClearsValue = currentValue != nil
            && "None".caseInsensitiveCompare(query) == .orderedSame
        let creatableValue = BeadStateLabel.normalizedValueInput(query).flatMap { value in
            queryMatch.hasMatch || queryClearsValue ? nil : value
        }
        let optionRowCount = visibleValues.count
            + (showsClearValue ? 1 : 0)
            + (creatableValue == nil ? 0 : 1)
        let rowCount = optionRowCount == 0
            ? 1
            : optionRowCount
        let visibleRowCount = min(max(rowCount, 1), 5)
        return StateValueSuggestions(
            visibleValues: visibleValues,
            creatableValue: creatableValue,
            showsClearValue: showsClearValue,
            archivedMatch: archivedMatch,
            queryMatch: queryMatch,
            listHeight: CGFloat(visibleRowCount * 34 + max(visibleRowCount - 1, 0) * 2)
        )
    }

    private func commitQuery() {
        if currentValue != nil,
           "None".caseInsensitiveCompare(trimmedQuery) == .orderedSame {
            commit(nil, normalizedReason)
            return
        }
        switch BeadStateValuePickerPolicy.match(
            query: trimmedQuery,
            in: candidateValues,
            followedBy: unavailableValues
        ) {
        case let .unique(value):
            guard isCandidate(value),
                  value.value != currentValue else { return }
            commit(value.value, normalizedReason)
        case .ambiguous:
            return
        case .none:
            guard let value = BeadStateLabel.normalizedValueInput(trimmedQuery),
                  value != currentValue else { return }
            commit(value, normalizedReason)
        }
    }

    private func isCandidate(_ value: BeadStateValuePresentation) -> Bool {
        !value.isArchived || value.value == currentValue
    }

    private func emptyMessage(for suggestions: StateValueSuggestions) -> String {
        if let archivedMatch = suggestions.archivedMatch {
            return "\(archivedMatch.displayName) is archived in Project Settings."
        }
        if case .ambiguous = suggestions.queryMatch {
            return "More than one value matches. Choose a value from the list."
        }
        return trimmedQuery.isEmpty ? "No values yet" : "No matching values"
    }
}

private struct StateValueSuggestions {
    let visibleValues: [BeadStateValuePresentation]
    let creatableValue: String?
    let showsClearValue: Bool
    let archivedMatch: BeadStateValuePresentation?
    let queryMatch: BeadStateValueQueryMatch
    let listHeight: CGFloat
}

private struct StateValueCreateRow: View {
    let value: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Set \"\(value)\"", systemImage: "plus")
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(isHovered ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Set \(value)")
    }
}
