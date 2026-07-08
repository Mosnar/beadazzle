import Foundation
import Observation

@MainActor
@Observable
final class BeadPickerModel {
    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            if !didEditQuickCreateTitle {
                quickCreateTitle = searchText
            }
        }
    }
    var filters = BeadPickerFilters()
    var mode = IssueListMode.outline
    var outlineState = BeadOutlineSelectionState()
    private(set) var rows: [BeadPickerRow] = []
    private(set) var selectableIssueIDs: [String] = []
    private(set) var isLoading = false
    var selectedIssueID: String?
    var isQuickCreateExpanded = false
    var quickCreateTitle = ""
    var quickCreateType = ""
    var quickCreatePriority = 2
    var quickCreateLabelsText = ""
    var quickCreateLabels: [String] {
        get {
            IssueDraft.normalizedLabels(quickCreateLabelsText)
        }
        set {
            quickCreateLabelsText = IssueDraft.normalizedLabelText(newValue)
        }
    }

    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var didEditQuickCreateTitle = false
    @ObservationIgnored private var selectableIssueIDSet: Set<String> = []

    var selectedRow: BeadPickerRow? {
        guard let selectedIssueID else { return nil }
        return rows.first { $0.issue.id == selectedIssueID && $0.isSelectable }
    }

    var canCreateQuickBead: Bool {
        !quickCreateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !quickCreateType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func configure(configuration: BeadPickerConfiguration, defaultDraft: IssueDraft) {
        guard !didConfigure else { return }
        didConfigure = true
        filters = configuration.initialFilters
        mode = configuration.initialMode
        quickCreateType = defaultDraft.issueType
        quickCreatePriority = defaultDraft.priority
        quickCreateLabelsText = defaultDraft.labelsText
    }

    func queryToken(configuration: BeadPickerConfiguration, contentRevision: Int) -> BeadPickerQueryToken {
        BeadPickerQueryToken(
            configuration: configuration,
            filters: filters,
            searchText: searchText,
            mode: mode,
            outlineState: outlineState,
            contentRevision: contentRevision
        )
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
    }

    func apply(_ result: BeadPickerQueryResult) {
        rows = result.rows
        selectableIssueIDs = result.rows.compactMap { $0.isSelectable ? $0.issue.id : nil }
        selectableIssueIDSet = Set(selectableIssueIDs)
        repairSelection()
    }

    func moveSelectionDown() {
        moveSelection(offset: 1)
    }

    func moveSelectionUp() {
        moveSelection(offset: -1)
    }

    func toggleExpansion(issueID: String) {
        guard let row = rows.first(where: { $0.issue.id == issueID })?.row, row.hasChildren else { return }
        outlineState.setExpansion(issueID: issueID, isExpanded: !row.isExpanded)
    }

    func toggleStatusFilter(_ status: String) {
        toggle(&filters.statusFilters, value: status)
    }

    func toggleTypeFilter(_ type: String) {
        toggle(&filters.typeFilters, value: type)
    }

    func togglePriorityFilter(_ priority: Int) {
        toggle(&filters.priorityFilters, value: priority)
    }

    func toggleLabelFilter(_ label: String) {
        toggle(&filters.labelFilters, value: label)
    }

    func clearFilters() {
        filters = BeadPickerFilters()
    }

    func setLabelFilters(_ labels: Set<String>) {
        guard filters.labelFilters != labels else { return }
        filters.labelFilters = labels
    }

    func setQuickCreateTitle(_ title: String) {
        didEditQuickCreateTitle = true
        quickCreateTitle = title
    }

    func isSelectable(issueID: String) -> Bool {
        selectableIssueIDSet.contains(issueID)
    }

    private func repairSelection() {
        if let selectedIssueID, selectableIssueIDSet.contains(selectedIssueID) {
            return
        }
        selectedIssueID = selectableIssueIDs.first
    }

    private func moveSelection(offset: Int) {
        guard !selectableIssueIDs.isEmpty else {
            selectedIssueID = nil
            return
        }
        guard let selectedIssueID,
              let currentIndex = selectableIssueIDs.firstIndex(of: selectedIssueID) else {
            self.selectedIssueID = selectableIssueIDs.first
            return
        }
        let nextIndex = min(
            max(currentIndex + offset, selectableIssueIDs.startIndex),
            selectableIssueIDs.index(before: selectableIssueIDs.endIndex)
        )
        self.selectedIssueID = selectableIssueIDs[nextIndex]
    }

    private func toggle<Value: Hashable>(_ values: inout Set<Value>, value: Value) {
        if values.contains(value) {
            values.remove(value)
        } else {
            values.insert(value)
        }
    }
}

struct BeadPickerQueryToken: Hashable {
    var configuration: BeadPickerConfiguration
    var filters: BeadPickerFilters
    var searchText: String
    var mode: IssueListMode
    var outlineState: BeadOutlineSelectionState
    var contentRevision: Int
}

enum BeadPickerQuickCreateField: Hashable {
    case title
}
