import SwiftUI

struct BulkEditPropertySections: Equatable {
    let pinned: [String]
    let other: [String]

    @MainActor
    init(store: BeadStore) {
        pinned = store.pinnedStateDimensions
        other = store.unpinnedStateDimensionOptions().sorted {
            store.stateDimensionDisplayName(for: $0).localizedStandardCompare(
                store.stateDimensionDisplayName(for: $1)
            ) == .orderedAscending
        }
    }

    var isEmpty: Bool { pinned.isEmpty && other.isEmpty }
}

struct BulkEditSheet: View {
    let request: BulkEditRequest

    var body: some View {
        switch request.payload {
        case .addLabels(let context):
            BulkAddLabelsSheet(request: request, context: context)
        case .setProperty(let dimension, let context):
            BulkSetPropertySheet(request: request, dimension: dimension, context: context)
        }
    }
}

private struct BulkAddLabelsSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss
    let request: BulkEditRequest
    let context: BulkAddLabelsContext
    @State private var query = ""
    @State private var selectedLabels: Set<String> = []
    @State private var isApplying = false
    @State private var isStopping = false
    @State private var progress: BulkMutationProgress?
    @State private var applyTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let queryState = context.queryState(for: trimmedQuery)
        let visibleLabels = context.visibleLabels(
            query: trimmedQuery,
            including: selectedLabels
        )

        VStack(alignment: .leading, spacing: 14) {
            BulkEditSheetHeader(
                title: "Add Labels",
                issueCount: context.issueCount,
                message: "Existing labels and properties are preserved."
            )

            LabelSearchField(text: $query)
                .onSubmit(addQueryLabels)

            if !selectedLabels.isEmpty {
                ScrollView {
                    LabelChipFlow(spacing: 6) {
                        ForEach(selectedLabels.sorted(), id: \.self) { label in
                            EditableLabelChip(label: label) {
                                selectedLabels.remove(label)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 84)
            }

            if queryState.usesManagedProperty {
                Label("Use Set Property for this label namespace.", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleLabels.isEmpty && !queryState.canCreate {
                        Text(trimmedQuery.isEmpty ? "No labels yet" : "No matching labels")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        ForEach(visibleLabels, id: \.self) { label in
                            let coverage = context.coverageCount(for: label)
                            BulkLabelOptionRow(
                                label: label,
                                detail: coverage == context.issueCount
                                    ? "All"
                                    : "\(coverage) of \(context.issueCount)",
                                isSelected: selectedLabels.contains(label),
                                isDisabled: coverage == context.issueCount
                            ) {
                                toggle(label)
                            }
                        }
                    }

                    if queryState.canCreate {
                        LabelCreateRow(query: trimmedQuery, action: addQueryLabels)
                    }
                }
            }
            .frame(minHeight: 150, maxHeight: 260)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedLabels.isEmpty || isApplying)
            }
        }
        .padding(18)
        .frame(width: 420)
        .disabled(isApplying)
        .interactiveDismissDisabled(isApplying)
        .overlay {
            if isApplying {
                BulkEditProgressView(
                    operation: "Adding labels",
                    progress: progress ?? BulkMutationProgress(totalCount: context.issueCount),
                    isStopping: isStopping,
                    stopRemaining: stopRemaining
                )
            }
        }
        .onDisappear {
            applyTask?.cancel()
            applyTask = nil
        }
    }

    private func toggle(_ label: String) {
        if selectedLabels.contains(label) {
            selectedLabels.remove(label)
        } else {
            selectedLabels.insert(label)
        }
    }

    private func addQueryLabels() {
        let queryState = context.queryState(for: trimmedQuery)
        guard !queryState.usesManagedProperty else { return }
        for label in queryState.resolvedLabels
        where context.coverageCount(for: label) < context.issueCount {
            selectedLabels.insert(label)
        }
        query = ""
    }

    private func apply() {
        guard !selectedLabels.isEmpty else { return }
        let labels = selectedLabels.sorted()
        isApplying = true
        isStopping = false
        progress = BulkMutationProgress(totalCount: context.issueCount)
        applyTask = Task { @MainActor in
            _ = await store.addLabels(
                issueIDs: request.issueIDs,
                labels: labels,
                expectedProjectURL: request.projectURL,
                progress: { updatedProgress in
                    if progress != updatedProgress {
                        progress = updatedProgress
                    }
                }
            )
            applyTask = nil
            isApplying = false
            dismiss()
        }
    }

    private func stopRemaining() {
        guard isApplying, !isStopping else { return }
        isStopping = true
        applyTask?.cancel()
    }
}

private struct BulkSetPropertySheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss
    let request: BulkEditRequest
    let dimension: String
    let context: BulkSetPropertyContext
    @State private var query = ""
    @State private var reason = ""
    @State private var selectedValue: String?
    @State private var isApplying = false
    @State private var isStopping = false
    @State private var progress: BulkMutationProgress?
    @State private var applyTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleValues: [BeadStateValuePresentation] {
        guard !trimmedQuery.isEmpty else { return context.candidateValues }
        return context.candidateValues.filter {
            $0.displayName.localizedStandardContains(trimmedQuery)
                || $0.value.localizedStandardContains(trimmedQuery)
        }
    }

    private var queryMatch: BeadStateValueQueryMatch {
        BeadStateValuePickerPolicy.match(
            query: trimmedQuery,
            in: context.catalog.active,
            followedBy: context.catalog.archived
        )
    }

    private var creatableValue: String? {
        guard !queryMatch.hasMatch else { return nil }
        return BeadStateLabel.normalizedValueInput(trimmedQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BulkEditSheetHeader(
                title: "Set \(context.displayName)",
                issueCount: context.issueCount,
                message: "Current value: \(context.currentSummary)"
            )

            LabelSearchField(text: $query)
                .onSubmit(selectQuery)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if visibleValues.isEmpty && creatableValue == nil {
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        ForEach(visibleValues) { value in
                            BulkPropertyValueRow(
                                value: value,
                                isSelected: selectedValue == value.value,
                                isDisabled: value.isArchived
                            ) {
                                selectedValue = value.value
                            }
                        }
                    }

                    if let creatableValue {
                        Button {
                            selectedValue = creatableValue
                            query = ""
                        } label: {
                            Label("Use \"\(creatableValue)\"", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 130, maxHeight: 230)

            if let selectedValue {
                LabeledContent("New value") {
                    Text(context.displayName(for: selectedValue))
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField("Reason (optional)", text: $reason)
                    .textFieldStyle(.roundedBorder)
                Text("Each changed bead gets its own entry in Activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedValue == nil || changedIssueCount == 0 || isApplying)
            }
        }
        .padding(18)
        .frame(width: 420)
        .disabled(isApplying)
        .interactiveDismissDisabled(isApplying)
        .overlay {
            if isApplying {
                BulkEditProgressView(
                    operation: "Setting \(context.displayName.lowercased())",
                    progress: progress ?? BulkMutationProgress(totalCount: changedIssueCount),
                    isStopping: isStopping,
                    stopRemaining: stopRemaining
                )
            }
        }
        .onDisappear {
            applyTask?.cancel()
            applyTask = nil
        }
    }

    private var changedIssueCount: Int {
        guard let selectedValue else { return 0 }
        return context.changedIssueCount(for: selectedValue)
    }

    private var emptyMessage: String {
        if case .ambiguous = queryMatch {
            return "More than one value matches. Choose one from the list."
        }
        if case .unique(let value) = queryMatch, value.isArchived {
            return "\(value.displayName) is archived in Project Settings."
        }
        return trimmedQuery.isEmpty ? "No values yet" : "No matching values"
    }

    private func selectQuery() {
        switch queryMatch {
        case .unique(let value) where !value.isArchived:
            selectedValue = value.value
            query = ""
        case .none:
            if let creatableValue {
                selectedValue = creatableValue
                query = ""
            }
        case .unique, .ambiguous:
            break
        }
    }

    private func apply() {
        guard let selectedValue, changedIssueCount > 0 else { return }
        let reason = reason
        isApplying = true
        isStopping = false
        progress = BulkMutationProgress(totalCount: changedIssueCount)
        applyTask = Task { @MainActor in
            _ = await store.bulkSetState(
                issueIDs: request.issueIDs,
                dimension: dimension,
                value: selectedValue,
                reason: reason,
                expectedProjectURL: request.projectURL,
                progress: { updatedProgress in
                    if progress != updatedProgress {
                        progress = updatedProgress
                    }
                }
            )
            applyTask = nil
            isApplying = false
            dismiss()
        }
    }

    private func stopRemaining() {
        guard isApplying, !isStopping else { return }
        isStopping = true
        applyTask?.cancel()
    }
}

private struct BulkEditProgressView: View {
    let operation: String
    let progress: BulkMutationProgress
    let isStopping: Bool
    let stopRemaining: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(operation)
                .font(.callout.weight(.medium))
            ProgressView(
                value: Double(progress.completedCount),
                total: Double(max(progress.totalCount, 1))
            )
            .frame(width: 190)
            .accessibilityLabel(operation)
            .accessibilityValue(progressAccessibilityValue)
            Text("Processed \(progress.completedCount.formatted()) of \(progress.totalCount.formatted())")
                .font(.caption)
                .monospacedDigit()
            if progress.completedCount > 0 {
                Text("\(progress.succeededCount.formatted()) succeeded · \(progress.failedCount.formatted()) failed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if isStopping {
                Text("Stopping after the current command…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Stop Remaining", role: .cancel, action: stopRemaining)
                .disabled(isStopping || progress.remainingCount == 0)
                .help("Keep completed changes and stop before the next command")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
    }

    private var progressAccessibilityValue: String {
        "\(progress.completedCount) of \(progress.totalCount) processed, \(progress.succeededCount) succeeded, \(progress.failedCount) failed"
    }
}

private struct BulkEditSheetHeader: View {
    let title: String
    let issueCount: Int
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text("\(issueCount.formatted()) selected bead\(issueCount == 1 ? "" : "s")")
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BulkLabelOptionRow: View {
    let label: String
    let detail: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isDisabled ? "checkmark.circle.fill" : "checkmark")
                    .frame(width: 14)
                    .foregroundStyle(isDisabled ? Color.secondary : Color.accentColor)
                    .opacity(isSelected || isDisabled ? 1 : 0)
                Text(label)
                    .lineLimit(1)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityValue(
            isDisabled ? "Already on all selected beads" : (isSelected ? "Selected" : "Not selected")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BulkPropertyValueRow: View {
    let value: BeadStateValuePresentation
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .frame(width: 14)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
                Text(value.displayName)
                    .lineLimit(1)
                Spacer()
                if value.isArchived {
                    Text("Archived")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityValue(
            isDisabled ? "Archived" : (isSelected ? "Selected" : "Not selected")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
