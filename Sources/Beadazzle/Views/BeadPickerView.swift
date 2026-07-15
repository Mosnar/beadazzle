import Observation
import SwiftUI

struct BeadPickerPopover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    let configuration: BeadPickerConfiguration
    let onApplied: (String?) -> Void
    let onDismiss: () -> Void

    @State private var model = BeadPickerModel()
    @State private var isApplying = false
    @State private var errorText: String?
    @State private var shouldFocusSearchField = true
    @State private var quickCreateFocusTask: Task<Void, Never>?
    @FocusState private var quickCreateFocusedField: BeadPickerQuickCreateField?

    var body: some View {
        @Bindable var model = model
        let defaultDraft = store.beadPickerDefaultDraft(for: configuration)
        let queryToken = model.queryToken(configuration: configuration, contentRevision: project.contentRevision)

        VStack(alignment: .leading, spacing: 0) {
            header
            BeadPickerDivider()
            results
            BeadPickerDivider()
            quickCreateFooter(defaultDraft: defaultDraft)
        }
        .frame(width: 430)
        .beadPickerPopoverSurface()
        .task(id: queryToken) {
            await refreshRows(queryToken)
        }
        .onAppear {
            model.configure(configuration: configuration, defaultDraft: defaultDraft)
        }
        .onDisappear {
            quickCreateFocusTask?.cancel()
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard quickCreateFocusedField == nil else { return .ignored }
            model.moveSelectionDown()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard quickCreateFocusedField == nil else { return .ignored }
            model.moveSelectionUp()
            return .handled
        }
        .onKeyPress(.return) {
            guard quickCreateFocusedField == nil else { return .ignored }
            applySelectedRow()
            return .handled
        }
        .onChange(of: quickCreateFocusedField) { _, focusedField in
            if focusedField != nil {
                shouldFocusSearchField = false
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(configuration.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Picker("Mode", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                    ForEach(IssueListMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .accessibilityLabel(mode.rawValue)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 70)
            }

            BeadPickerSearchBar(
                text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
                placeholder: configuration.prompt,
                wantsFocus: shouldFocusSearchField,
                focus: {
                    shouldFocusSearchField = true
                    quickCreateFocusedField = nil
                },
                moveUp: { model.moveSelectionUp() },
                moveDown: { model.moveSelectionDown() },
                submit: applySelectedRow,
                dismiss: onDismiss
            )

            filterBar
        }
        .padding(12)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            BeadPickerFilterMenu(
                title: "Status",
                systemImage: "circle.dashed",
                activeCount: model.filters.statusFilters.count
            ) {
                ForEach(store.statusOptions(including: nil), id: \.self) { status in
                    BeadPickerFilterButton(
                        title: status,
                        isSelected: model.filters.statusFilters.contains(status)
                    ) {
                        model.toggleStatusFilter(status)
                    }
                }
            }

            BeadPickerFilterMenu(
                title: "Type",
                systemImage: "tag",
                activeCount: model.filters.typeFilters.count
            ) {
                ForEach(store.mutableTypeOptions(including: nil), id: \.self) { type in
                    BeadPickerFilterButton(
                        title: type,
                        isSelected: model.filters.typeFilters.contains(type)
                    ) {
                        model.toggleTypeFilter(type)
                    }
                }
            }

            BeadPickerFilterMenu(
                title: "P",
                systemImage: "exclamationmark.triangle",
                activeCount: model.filters.priorityFilters.count
            ) {
                ForEach(Array(0...4), id: \.self) { priority in
                    BeadPickerFilterButton(
                        title: "P\(priority)",
                        isSelected: model.filters.priorityFilters.contains(priority)
                    ) {
                        model.togglePriorityFilter(priority)
                    }
                }
            }

            if !store.availableLabels.isEmpty || !model.filters.labelFilters.isEmpty {
                BeadPickerLabelFilterControl(
                    selectedLabels: Binding(
                        get: { model.filters.labelFilters },
                        set: { model.setLabelFilters($0) }
                    ),
                    availableLabels: store.availableLabels
                )
            }

            Spacer(minLength: 8)

            if !model.filters.isEmpty {
                Button {
                    model.clearFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear filters")
                .accessibilityLabel("Clear filters")
            }
        }
        .controlSize(.small)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if configuration.action.allowsClearParent {
                        BeadPickerClearParentRow(isApplying: isApplying) {
                            clearParent()
                        }
                        .padding(.horizontal, BeadPickerChrome.rowHorizontalInset)

                        BeadPickerDivider()
                            .padding(.vertical, 4)
                    }

                    if model.rows.isEmpty {
                        BeadPickerEmptyRow(isLoading: model.isLoading)
                    } else {
                        ForEach(model.rows) { pickerRow in
                            BeadPickerResultRow(
                                pickerRow: pickerRow,
                                isSelected: pickerRow.issue.id == model.selectedIssueID,
                                mode: model.mode,
                                isApplying: isApplying,
                                toggleExpansion: {
                                    model.toggleExpansion(issueID: pickerRow.issue.id)
                                },
                                select: {
                                    apply(issueID: pickerRow.issue.id)
                                }
                            )
                            .id(pickerRow.issue.id)
                            .padding(.horizontal, BeadPickerChrome.rowHorizontalInset)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: 326)
            .onChange(of: model.selectedIssueID) { _, issueID in
                guard let issueID else { return }
                withAnimation(.snappy(duration: 0.12)) {
                    proxy.scrollTo(issueID, anchor: .center)
                }
            }
        }
    }

    private func quickCreateFooter(defaultDraft: IssueDraft) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }

            if let quickCreate = configuration.quickCreate {
                Button(action: toggleQuickCreate) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                            .rotationEffect(.degrees(model.isQuickCreateExpanded ? 90 : 0))

                        Label(quickCreate.title, systemImage: "plus.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.callout.weight(.semibold))

                        Spacer()
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isApplying)

                BeadPickerCollapsible(isExpanded: model.isQuickCreateExpanded, reduceMotion: reduceMotion) {
                    quickCreateForm(defaultDraft: defaultDraft, quickCreate: quickCreate)
                        .padding(.top, 8)
                }
            }
        }
        .padding(12)
        .animation(BeadPickerChrome.quickCreateAnimation(reduceMotion: reduceMotion), value: model.isQuickCreateExpanded)
    }

    private func quickCreateForm(defaultDraft: IssueDraft, quickCreate: QuickCreateConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BeadPickerQuickCreateTextField(
                systemImage: "text.cursor",
                placeholder: "Title",
                text: Binding(
                    get: { model.quickCreateTitle },
                    set: { model.setQuickCreateTitle($0) }
                ),
                focusedField: $quickCreateFocusedField,
                focusID: .title,
                isDisabled: isApplying
            )

            HStack(spacing: 8) {
                BeadPickerQuickCreateTypeMenu(
                    selectedType: Binding(
                        get: { model.quickCreateType },
                        set: { model.quickCreateType = $0 }
                    ),
                    typeOptions: store.beadPickerQuickCreateTypeOptions(
                        action: configuration.action,
                        including: model.quickCreateType
                    ),
                    isDisabled: isApplying
                )
                .frame(minWidth: 118, idealWidth: 136, maxWidth: 154, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 8)

                BeadPickerQuickCreatePriorityControl(
                    priority: Binding(
                        get: { model.quickCreatePriority },
                        set: { model.quickCreatePriority = $0 }
                    )
                )
                .disabled(isApplying)
                .frame(width: 190)
            }

            HStack(spacing: 8) {
                BeadPickerQuickCreateLabelsControl(
                    labels: Binding(
                        get: { model.quickCreateLabels },
                        set: { model.quickCreateLabels = $0 }
                    ),
                    availableLabels: store.availableLabels,
                    isDisabled: isApplying
                )
                .layoutPriority(1)

                Button(quickCreate.createButtonTitle) {
                    createQuickBead(defaultDraft: defaultDraft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isApplying || !model.canCreateQuickBead)
            }
        }
        .padding(10)
        .background(BeadPickerChrome.groupFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BeadPickerChrome.controlStroke, lineWidth: 1)
        }
    }

    private func refreshRows(_ token: BeadPickerQueryToken) async {
        model.setLoading(true)
        let result = await store.beadPickerRows(
            configuration: token.configuration,
            filters: token.filters,
            searchText: token.searchText,
            mode: token.mode,
            outlineState: token.outlineState
        )
        guard !Task.isCancelled else { return }
        model.apply(result)
        model.setLoading(false)
    }

    private func applySelectedRow() {
        guard let selectedIssueID = model.selectedIssueID else { return }
        apply(issueID: selectedIssueID)
    }

    private func toggleQuickCreate() {
        if model.quickCreateTitle.isEmpty {
            model.setQuickCreateTitle(model.searchText)
        }

        withAnimation(BeadPickerChrome.quickCreateAnimation(reduceMotion: reduceMotion)) {
            model.isQuickCreateExpanded.toggle()
        }

        quickCreateFocusTask?.cancel()
        if model.isQuickCreateExpanded {
            shouldFocusSearchField = false
            quickCreateFocusTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, model.isQuickCreateExpanded else { return }
                quickCreateFocusedField = .title
            }
        } else {
            quickCreateFocusedField = nil
            shouldFocusSearchField = true
        }
    }

    private func apply(issueID: String) {
        guard !isApplying,
              model.isSelectable(issueID: issueID) else { return }
        isApplying = true
        errorText = nil
        Task { @MainActor in
            let didApply = await store.applyBeadPickerSelection(issueID, action: configuration.action)
            isApplying = false
            if didApply {
                onApplied(issueID)
                onDismiss()
            } else {
                errorText = store.lastError ?? "Could not update the relationship."
            }
        }
    }

    private func clearParent() {
        guard !isApplying,
              case .setParent(let issueID) = configuration.action else { return }
        isApplying = true
        errorText = nil
        Task { @MainActor in
            let didApply = await store.setParent(issueID: issueID, parentID: nil)
            isApplying = false
            if didApply {
                onApplied(nil)
                onDismiss()
            } else {
                errorText = store.lastError ?? "Could not clear the parent bead."
            }
        }
    }

    private func createQuickBead(defaultDraft: IssueDraft) {
        guard !isApplying, model.canCreateQuickBead else { return }
        isApplying = true
        errorText = nil
        Task { @MainActor in
            var draft = defaultDraft
            draft.title = model.quickCreateTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.issueType = model.quickCreateType
            draft.priority = model.quickCreatePriority
            draft.labelsText = model.quickCreateLabelsText

            guard let createdIssueID = await store.createBead(draft, revealCreated: false) else {
                isApplying = false
                errorText = store.lastError ?? "Could not create the bead."
                return
            }

            let didApply = await store.applyBeadPickerQuickCreate(createdIssueID, action: configuration.action)
            isApplying = false
            if didApply {
                onApplied(createdIssueID)
                onDismiss()
            } else {
                errorText = store.lastError ?? "Created \(createdIssueID), but could not update the relationship."
            }
        }
    }
}
