import SwiftUI

struct SavedViewEditorRequest: Identifiable {
    enum Mode { case create, edit(UUID) }
    var mode: Mode
    var id: String {
        switch mode {
        case .create: "create"
        case .edit(let id): "edit-\(id)"
        }
    }
}

struct SaveBookmarkSheet: View {
    @Environment(BeadStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let existingID: UUID?
    @State private var name: String
    @State private var symbolName: String
    @State private var filter: BeadSavedViewFilter
    @State private var preview: BeadSavedViewPreview?
    @State private var isLoadingPreview = false
    @State private var currentFiltersExpanded = false
    @FocusState private var nameIsFocused: Bool

    init(existing: BeadSavedView?, initialFilter: BeadSavedViewFilter, suggestedName: String, initialSymbolName: String) {
        existingID = existing?.id
        _name = State(initialValue: existing?.name ?? suggestedName)
        _symbolName = State(initialValue: existing?.symbolName ?? BeadSavedViewSymbols.normalized(initialSymbolName))
        _filter = State(initialValue: existing?.filter ?? initialFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    basicQuerySection
                    advancedRulesSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 620, minHeight: 500, idealHeight: 500)
        .onAppear { nameIsFocused = true }
        .task(id: filter) {
            isLoadingPreview = true
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let nextPreview = await store.previewSavedView(filter)
            guard !Task.isCancelled else { return }
            preview = nextPreview
            isLoadingPreview = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(existingID == nil ? "New Bookmark" : "Configure Bookmark")
                .font(.headline)
            TextField("Bookmark Name", text: $name)
                .focused($nameIsFocused)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var basicQuerySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                currentFiltersExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(currentFiltersExpanded ? 90 : 0))
                        .frame(width: 16)
                    Label("Current View", systemImage: "line.3.horizontal.decrease.circle")
                        .fontWeight(.medium)
                    Spacer()
                    Text(compactCurrentViewSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(currentFiltersExpanded ? "Collapse Current View" : "Expand Current View")
            .accessibilityValue(compactCurrentViewSummary)

            if currentFiltersExpanded {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow {
                    Text("Base")
                    Picker("Base", selection: $filter.basePreset) {
                        ForEach(BeadBookmark.allCases) { bookmark in
                            Text(bookmark.title).tag(BeadBookmarkToken(bookmark))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Status")
                    FilterValueMultiSelect(field: .status, options: store.availableStatuses, selection: $filter.statusFilters)
                }
                GridRow {
                    Text("Type")
                    FilterValueMultiSelect(field: .type, options: store.availableTypes, selection: $filter.typeFilters)
                }
                GridRow {
                    Text("Priority")
                    FilterValueMultiSelect(field: .priority, options: (0...4).map(String.init), selection: priorityStringBinding)
                }
                GridRow {
                    Text("Labels")
                    FilterValueMultiSelect(field: .labels, options: store.availableLabels, selection: $filter.labelFilters)
                }
                GridRow {
                    Text("Search")
                    TextField("Search text", text: $filter.searchText)
                }
                GridRow {
                    Text("Sort")
                    HStack {
                        Picker("Sort", selection: $filter.sort) {
                            ForEach(IssueSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Direction", selection: $filter.sortDirection) {
                            ForEach(SortDirection.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    .labelsHidden()
                }
                }
                .padding(.top, 12)
                .padding(.leading, 24)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
    }

    private var advancedRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Additional Rules", systemImage: "switch.2")
                    .fontWeight(.medium)
                Spacer()
                if filter.advancedPredicate != nil {
                    Button("Clear") { filter.advancedPredicate = nil }
                        .controlSize(.small)
                }
                Button {
                    if filter.advancedPredicate == nil {
                        filter.advancedPredicate = BeadFilterGroup(children: [.condition(BeadFilterCondition())])
                    } else {
                        filter.advancedPredicate?.children.append(.condition(BeadFilterCondition()))
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if filter.advancedPredicate == nil {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No additional rules")
                        Text("Add people, date, text, hierarchy, relationship, or activity filters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
            } else {
                FilterGroupEditor(group: advancedGroupBinding, depth: 0)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if isLoadingPreview {
                ProgressView().controlSize(.small)
                Text("Updating preview…").foregroundStyle(.secondary)
            } else if let preview {
                Text("\(preview.count.formatted()) matching")
                    .fontWeight(.medium)
                if !preview.sample.isEmpty {
                    Text(preview.sample.map(\.id).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existingID == nil ? "Save Bookmark" : "Save Changes", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(12)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (filter.advancedPredicate?.isValid ?? true)
    }

    private var advancedGroupBinding: Binding<BeadFilterGroup> {
        Binding(
            get: { filter.advancedPredicate ?? BeadFilterGroup() },
            set: { filter.advancedPredicate = $0 }
        )
    }

    private var priorityStringBinding: Binding<Set<String>> {
        Binding(
            get: { Set(filter.priorityFilters.map(String.init)) },
            set: { filter.priorityFilters = Set($0.compactMap(Int.init)) }
        )
    }

    private var compactCurrentViewSummary: String {
        var parts = [filter.basePreset.bookmark.title]
        let filterCount = filter.statusFilters.count + filter.typeFilters.count
            + filter.priorityFilters.count + filter.labelFilters.count
        if filterCount > 0 { parts.append("\(filterCount) filter\(filterCount == 1 ? "" : "s")") }
        if !filter.searchText.isEmpty { parts.append("search") }
        parts.append(filter.sort.rawValue)
        return parts.joined(separator: " · ")
    }

    private func save() {
        filter.advancedPredicate = filter.advancedPredicate?.normalized
        if let existingID {
            store.updateConfiguredView(id: existingID, name: name, symbolName: symbolName, filter: filter)
        } else {
            store.saveConfiguredView(name: name, symbolName: symbolName, filter: filter)
        }
        dismiss()
    }
}

private struct FilterGroupEditor: View {
    @Binding var group: BeadFilterGroup
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Group matching", selection: $group.match) {
                    ForEach(BeadFilterGroupMatch.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Text("of the following")
                    .foregroundStyle(.secondary)
                Spacer()
                if depth < 2 {
                    Button("Add Group") {
                        group.children.append(.group(BeadFilterGroup(children: [.condition(BeadFilterCondition())])))
                    }
                    .controlSize(.small)
                }
            }

            ForEach(group.children) { node in
                HStack(alignment: .top, spacing: 8) {
                    switch node {
                    case .condition:
                        FilterConditionEditor(condition: conditionBinding(id: node.id))
                    case .group:
                        NestedFilterGroupEditor(group: groupBinding(id: node.id), depth: depth + 1)
                    }
                    Button(role: .destructive) {
                        group.children.removeAll { $0.id == node.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove rule")
                }
            }

            Button {
                group.children.append(.condition(BeadFilterCondition()))
            } label: {
                Label("Add Rule", systemImage: "plus")
            }
            .buttonStyle(.link)
        }
        .padding(8)
    }

    private func conditionBinding(id: UUID) -> Binding<BeadFilterCondition> {
        Binding(
            get: {
                guard let node = group.children.first(where: { $0.id == id }), case .condition(let value) = node else {
                    return BeadFilterCondition(id: id)
                }
                return value
            },
            set: { value in
                guard let index = group.children.firstIndex(where: { $0.id == id }) else { return }
                group.children[index] = .condition(value)
            }
        )
    }

    private func groupBinding(id: UUID) -> Binding<BeadFilterGroup> {
        Binding(
            get: {
                guard let node = group.children.first(where: { $0.id == id }), case .group(let value) = node else {
                    return BeadFilterGroup(id: id)
                }
                return value
            },
            set: { value in
                guard let index = group.children.firstIndex(where: { $0.id == id }) else { return }
                group.children[index] = .group(value)
            }
        )
    }
}

private struct NestedFilterGroupEditor: View {
    @Binding var group: BeadFilterGroup
    let depth: Int
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16)
                    Text("Rule Group")
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            if isExpanded {
                FilterGroupEditor(group: $group, depth: depth)
                    .padding(.leading, 12)
            }
        }
    }
}

private struct FilterConditionEditor: View {
    @Environment(BeadStore.self) private var store
    @Binding var condition: BeadFilterCondition

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: fieldBinding) {
                ForEach(BeadFilterField.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 145)

            Picker("Operation", selection: $condition.operation) {
                ForEach(condition.field.operations) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)

            valueEditor
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var valueEditor: some View {
        if !condition.operation.needsValue {
            Text("—").foregroundStyle(.tertiary)
        } else if [.before, .after, .on].contains(condition.operation) {
            DatePicker("Date", selection: $condition.value.date, displayedComponents: .date).labelsHidden()
        } else if [.inTheLast, .notInTheLast].contains(condition.operation) {
            HStack {
                TextField("Amount", value: $condition.value.relativeAmount, format: .number)
                    .frame(width: 55)
                Picker("Unit", selection: $condition.value.relativeUnit) {
                    ForEach(BeadRelativeDateUnit.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
            }
        } else if [.equals, .greaterThan, .lessThan].contains(condition.operation) {
            TextField("Number", value: $condition.value.number, format: .number)
        } else if condition.field == .parent, [.isEqual, .isNot].contains(condition.operation) {
            FilterParentPicker(selection: $condition.value.text)
        } else if [.isAnyOf, .isNoneOf, .containsAny, .containsAll, .containsNone].contains(condition.operation),
                  let choiceOptions {
            FilterValueMultiSelect(
                field: condition.field,
                options: choiceOptions,
                selection: $condition.value.strings
            )
        } else if [.isAnyOf, .isNoneOf, .containsAny, .containsAll, .containsNone].contains(condition.operation) {
            TextField("Comma-separated values", text: stringSetBinding)
        } else if condition.operation == .contains, let choiceOptions {
            FilterSuggestionTextField(field: condition.field, options: choiceOptions, text: $condition.value.text)
        } else {
            TextField("Value", text: $condition.value.text)
        }
    }

    private var choiceOptions: [String]? {
        switch condition.field {
        case .status: store.availableStatuses
        case .type: store.availableTypes
        case .priority: (0...4).map(String.init)
        case .labels: store.availableLabels
        case .owner: store.availableOwners
        case .assignee: store.availableAssignees
        default: nil
        }
    }

    private var fieldBinding: Binding<BeadFilterField> {
        Binding(
            get: { condition.field },
            set: { field in
                condition.field = field
                condition.operation = field.operations[0]
                condition.value = BeadFilterValue()
            }
        )
    }

    private var stringSetBinding: Binding<String> {
        Binding(
            get: { condition.value.strings.sorted().joined(separator: ", ") },
            set: { text in
                condition.value.strings = Set(text.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty })
            }
        )
    }
}

private struct FilterValueMultiSelect: View {
    let field: BeadFilterField
    let options: [String]
    @Binding var selection: Set<String>
    @State private var isPresented = false
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(summary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(field.title)
        .accessibilityValue(summary)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("Search \(field.title.lowercased())", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .padding(10)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredOptions, id: \.self) { option in
                            Toggle(isOn: selectionBinding(for: option)) {
                                Text(displayName(for: option))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Divider()

                HStack {
                    if !selection.isEmpty {
                        Button("Clear") { selection.removeAll() }
                    }
                    Spacer()
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
            .frame(width: 260, height: 300)
            .onAppear { searchIsFocused = true }
        }
    }

    private var filteredOptions: [String] {
        let allOptions = Array(Set(options).union(selection)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !searchText.isEmpty else { return allOptions }
        return allOptions.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var summary: String {
        switch selection.count {
        case 0: "Choose \(field.title.lowercased())…"
        case 1: displayName(for: selection.first ?? "")
        default: "\(selection.count) selected"
        }
    }

    private func displayName(for option: String) -> String {
        conditionallyFormattedPriority(option) ?? option
    }

    private func conditionallyFormattedPriority(_ option: String) -> String? {
        field == .priority ? "P\(option)" : nil
    }

    private func selectionBinding(for option: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(option) },
            set: { isSelected in
                if isSelected { selection.insert(option) } else { selection.remove(option) }
            }
        )
    }
}

private struct FilterSuggestionTextField: View {
    let field: BeadFilterField
    let options: [String]
    @Binding var text: String

    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(12).map { $0 }
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Value", text: $text)
            Menu {
                if suggestions.isEmpty {
                    Text("No Suggestions")
                } else {
                    ForEach(suggestions, id: \.self) { option in
                        Button(option) { text = option }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Show \(field.title) suggestions")
        }
    }
}

private struct FilterParentPicker: View {
    @Environment(BeadStore.self) private var store
    @Binding var selection: String
    @State private var isPresented = false
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

    private var matches: [BeadIssue] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.issues.lazy.filter { issue in
            query.isEmpty
                || issue.id.localizedCaseInsensitiveContains(query)
                || issue.title.localizedCaseInsensitiveContains(query)
        }.prefix(100).map { $0 }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                Text(selection.isEmpty ? "Choose parent…" : selection)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Parent bead")
        .accessibilityValue(selection.isEmpty ? "None selected" : selection)
        .popover(isPresented: $isPresented) {
            VStack(spacing: 0) {
                TextField("Search beads", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchIsFocused)
                    .padding(10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { issue in
                            Button {
                                selection = issue.id
                                isPresented = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.title).lineLimit(1)
                                    Text(issue.id).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                HStack {
                    if !selection.isEmpty {
                        Button("Clear") { selection = ""; isPresented = false }
                    }
                    Spacer()
                    Button("Cancel") { isPresented = false }
                }
                .padding(10)
            }
            .frame(width: 360, height: 340)
            .onAppear { searchIsFocused = true }
        }
    }
}
