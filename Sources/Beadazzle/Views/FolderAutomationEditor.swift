import SwiftUI

struct FolderAutomationEditor: View {
    @Environment(BeadStore.self) private var store

    let folderName: String
    let validationMessage: String?
    @Binding var draft: BeadFolderAutomationDraft
    @State private var isEditingAddedLabels = false
    @State private var isEditingRemovedLabels = false
    @State private var editingPropertyDimension: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("When a bead is added")
                    .font(.headline)
                Text("Actions run in the background in the order shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            addActionMenu
        }

        if !draft.hasConfiguredAction {
            ContentUnavailableView(
                "No Actions",
                systemImage: "bolt.badge.clock",
                description: Text("Adding a bead will only add it to the folder.")
            )
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    automationRows
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Automation error: \(validationMessage)")
            } else if !draft.propertyAssignments.isEmpty {
                Text("Property actions are recorded in Activity as “Folder automation: \(folderName)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var automationRows: some View {
        if let labelsToAdd = draft.labelsToAdd {
            FolderAutomationActionRow(
                title: "Add Labels",
                detail: labelsToAdd.isEmpty ? "Choose labels" : labelsToAdd.joined(separator: ", "),
                systemImage: "tag.fill",
                remove: {
                    draft.labelsToAdd = nil
                }
            ) {
                isEditingAddedLabels = true
            }
            .popover(isPresented: $isEditingAddedLabels) {
                LabelEditorPopover(
                    labels: labelsToAddBinding,
                    availableLabels: store.availableLabels,
                    title: "Add Labels",
                    managedStateDimensions: managedStateDimensions,
                    excludedLabels: Set(draft.labelsToRemove ?? [])
                )
            }
        }

        if let labelsToRemove = draft.labelsToRemove {
            FolderAutomationActionRow(
                title: "Remove Labels",
                detail: labelsToRemove.isEmpty ? "Choose labels" : labelsToRemove.joined(separator: ", "),
                systemImage: "tag.slash",
                remove: {
                    draft.labelsToRemove = nil
                }
            ) {
                isEditingRemovedLabels = true
            }
            .popover(isPresented: $isEditingRemovedLabels) {
                LabelEditorPopover(
                    labels: labelsToRemoveBinding,
                    availableLabels: store.availableLabels,
                    title: "Remove Labels",
                    allowsCreatingLabels: false,
                    managedStateDimensions: managedStateDimensions,
                    excludedLabels: Set(draft.labelsToAdd ?? [])
                )
            }
        }

        if let status = draft.status {
            HStack(spacing: 6) {
                Menu {
                    ForEach(store.folderAutomationStatusOptions, id: \.self) { option in
                        Button {
                            draft.status = option
                        } label: {
                            if option == status {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                } label: {
                    FolderAutomationActionLabel(
                        title: "Update Status",
                        detail: status,
                        systemImage: store.statusSymbol(for: status)
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)

                Button("Remove Update Status Action", systemImage: "minus.circle", role: .destructive) {
                    draft.status = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }

        ForEach(draft.propertyAssignments) { assignment in
            FolderAutomationActionRow(
                title: "Update \(store.stateDimensionDisplayName(for: assignment.dimension))",
                detail: assignment.value.isEmpty
                    ? "Choose value"
                    : store.stateValuePresentation(
                        for: assignment.value,
                        in: assignment.dimension
                    ).displayName,
                systemImage: "slider.horizontal.3",
                remove: {
                    draft.propertyAssignments.removeAll {
                        $0.dimension == assignment.dimension
                    }
                }
            ) {
                editingPropertyDimension = assignment.dimension
            }
            .popover(
                isPresented: Binding(
                    get: { editingPropertyDimension == assignment.dimension },
                    set: { if !$0 { editingPropertyDimension = nil } }
                )
            ) {
                let presentation = assignment.value.isEmpty
                    ? nil
                    : store.stateValuePresentation(
                        for: assignment.value,
                        in: assignment.dimension
                    )
                StateValuePickerPopover(
                    displayName: store.stateDimensionDisplayName(for: assignment.dimension),
                    currentValue: assignment.value.nilIfBlank,
                    currentPresentation: presentation,
                    catalog: store.stateValueCatalog(for: assignment.dimension),
                    showsReasonField: false
                ) { value, _ in
                    guard let value,
                          let index = draft.propertyAssignments.firstIndex(where: {
                              $0.dimension == assignment.dimension
                          })
                    else { return }
                    draft.propertyAssignments[index].value = value
                    editingPropertyDimension = nil
                }
            }
        }
    }

    private var addActionMenu: some View {
        Menu("Add Action", systemImage: "plus") {
            Button("Add Labels", systemImage: "tag.fill") {
                draft.labelsToAdd = []
                isEditingAddedLabels = true
            }
            .disabled(draft.labelsToAdd != nil)

            Button("Remove Labels", systemImage: "tag.slash") {
                draft.labelsToRemove = []
                isEditingRemovedLabels = true
            }
            .disabled(draft.labelsToRemove != nil || store.availableLabels.isEmpty)

            Button("Update Status", systemImage: "arrow.triangle.2.circlepath") {
                draft.status = store.folderAutomationStatusOptions.first
            }
            .disabled(draft.status != nil || store.folderAutomationStatusOptions.isEmpty)

            Menu("Update Property", systemImage: "slider.horizontal.3") {
                ForEach(availablePropertyDimensions, id: \.self) { dimension in
                    Button(store.stateDimensionDisplayName(for: dimension)) {
                        addProperty(dimension)
                    }
                }
            }
            .disabled(availablePropertyDimensions.isEmpty)
        }
        .menuIndicator(.visible)
    }

    private var labelsToAddBinding: Binding<[String]> {
        Binding(
            get: { draft.labelsToAdd ?? [] },
            set: { draft.labelsToAdd = $0 }
        )
    }

    private var labelsToRemoveBinding: Binding<[String]> {
        Binding(
            get: { draft.labelsToRemove ?? [] },
            set: { draft.labelsToRemove = $0 }
        )
    }

    private var managedStateDimensions: Set<String> {
        Set(store.pinnedStateDimensions)
            .union(draft.propertyAssignments.map(\.dimension))
    }

    private var availablePropertyDimensions: [String] {
        let sections = BulkEditPropertySections(store: store)
        let used = Set(draft.propertyAssignments.map(\.dimension))
        return (sections.pinned + sections.other).filter { dimension in
            !used.contains(dimension)
        }
    }

    private func addProperty(_ dimension: String) {
        draft.propertyAssignments.append(BeadFolderPropertyAssignment(
            dimension: dimension,
            value: ""
        ))
        editingPropertyDimension = dimension
    }
}

private struct FolderAutomationActionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let remove: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                FolderAutomationActionLabel(
                    title: title,
                    detail: detail,
                    systemImage: systemImage
                )
            }
            .buttonStyle(.plain)

            Button("Remove \(title) Action", systemImage: "minus.circle", role: .destructive, action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FolderAutomationActionLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
