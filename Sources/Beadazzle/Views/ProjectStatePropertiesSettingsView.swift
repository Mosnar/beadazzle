import SwiftUI

struct ProjectStatePropertiesSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var presentedSheet: ProjectStatePropertySheet?
    @State private var selectedDimension: String?

    var body: some View {
        let pinnedDimensions = store.pinnedStateDimensions
        let availableDimensions = store.unpinnedStateDimensionOptions()
        let pinnedProperties = pinnedDimensions.enumerated().map { index, dimension in
            ProjectPinnedStateProperty(
                dimension: dimension,
                displayName: store.stateDimensionDisplayName(for: dimension),
                canMoveUp: index > 0,
                canMoveDown: index + 1 < pinnedDimensions.count
            )
        }
        let otherProperties = availableDimensions.map { dimension in
            ProjectOtherStateProperty(
                dimension: dimension,
                displayName: store.stateDimensionDisplayName(for: dimension)
            )
        }
        let visibleDimensions = pinnedDimensions + availableDimensions
        let valueCatalog = selectedDimension.map {
            store.stateValueCatalog(for: $0)
        } ?? .empty

        HSplitView {
            ProjectPinnedStatePropertiesPane(
                properties: pinnedProperties,
                otherProperties: otherProperties,
                selection: $selectedDimension,
                addProperty: {
                    presentedSheet = .add
                },
                pinProperty: pinStateProperty,
                pinDroppedProperties: pinDroppedStateProperties,
                editProperty: editStateProperty,
                movePropertyUp: { dimension in
                    store.movePinnedStateDimensionUp(dimension)
                },
                movePropertyDown: { dimension in
                    store.movePinnedStateDimensionDown(dimension)
                },
                moveProperties: { offsets, destination in
                    store.movePinnedStateDimensions(fromOffsets: offsets, toOffset: destination)
                },
                unpinProperty: unpinStateProperty
            )
            .padding(.trailing, 16)
            .frame(minWidth: 280, idealWidth: 310, maxWidth: .infinity, maxHeight: .infinity)

            ProjectStatePropertyValuesPane(
                dimension: selectedDimension,
                displayName: selectedDimension.map {
                    store.stateDimensionDisplayName(for: $0)
                },
                catalog: valueCatalog
            )
            .padding(.leading, 16)
            .frame(minWidth: 280, idealWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 16)
        .padding(.horizontal, SettingsWindowLayout.contentMargin)
        .padding(.bottom, SettingsWindowLayout.contentMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: visibleDimensions) {
            guard let selectedDimension,
                  !visibleDimensions.contains(selectedDimension) else { return }
            self.selectedDimension = nil
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .add:
                ProjectStatePropertyAddSheet { dimension in
                    guard store.pinStateDimension(dimension) else { return false }
                    selectedDimension = dimension
                    return true
                }
            case let .edit(dimension):
                ProjectStatePropertyEditSheet(
                    dimension: dimension,
                    initialDisplayName: store.stateDimensionDisplayName(for: dimension)
                )
            }
        }
    }

    private func pinStateProperty(_ dimension: String) {
        guard store.pinStateDimension(dimension) else { return }
        selectedDimension = dimension
    }

    private func pinDroppedStateProperties(_ dimensions: [String], before destination: String?) -> Bool {
        let availableDimensions = Set(store.unpinnedStateDimensionOptions())
        var seenDimensions: Set<String> = []
        var insertionIndex = destination.flatMap {
            store.pinnedStateDimensions.firstIndex(of: $0)
        } ?? store.pinnedStateDimensions.endIndex
        var didPinProperty = false

        for dimension in dimensions
        where availableDimensions.contains(dimension) && seenDimensions.insert(dimension).inserted {
            guard store.pinStateDimension(dimension, at: insertionIndex) else { continue }
            insertionIndex += 1
            selectedDimension = dimension
            didPinProperty = true
        }

        return didPinProperty
    }

    private func editStateProperty(_ dimension: String) {
        presentedSheet = .edit(dimension)
    }

    private func unpinStateProperty(_ dimension: String) {
        store.unpinStateDimension(dimension)
    }
}

private struct ProjectPinnedStateProperty: Identifiable {
    let dimension: String
    let displayName: String
    let canMoveUp: Bool
    let canMoveDown: Bool

    var id: String { dimension }
}

private struct ProjectOtherStateProperty: Identifiable {
    let dimension: String
    let displayName: String

    var id: String { dimension }
}

private struct ProjectPinnedStatePropertiesPane: View {
    let properties: [ProjectPinnedStateProperty]
    let otherProperties: [ProjectOtherStateProperty]
    @Binding var selection: String?
    let addProperty: () -> Void
    let pinProperty: (String) -> Void
    let pinDroppedProperties: ([String], String?) -> Bool
    let editProperty: (String) -> Void
    let movePropertyUp: (String) -> Void
    let movePropertyDown: (String) -> Void
    let moveProperties: (IndexSet, Int) -> Void
    let unpinProperty: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinned Properties")
                .font(.headline)
                .dropDestination(for: String.self) { dimensions, _ in
                    pinDroppedProperties(dimensions, properties.first?.dimension)
                }

            List(selection: $selection) {
                if properties.isEmpty, !otherProperties.isEmpty {
                    Label("No Pinned Properties", systemImage: "pin")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dropDestination(for: String.self) { dimensions, _ in
                            pinDroppedProperties(dimensions, nil)
                        }
                }

                ForEach(properties) { property in
                    ProjectStatePropertyRow(
                        dimension: property.dimension,
                        displayName: property.displayName,
                        isSelected: selection == property.dimension,
                        membershipAction: .unpin,
                        edit: {
                            editProperty(property.dimension)
                        },
                        updateMembership: {
                            unpinProperty(property.dimension)
                        }
                    )
                    .contextMenu {
                        Button("Edit Display Name…") {
                            editProperty(property.dimension)
                        }

                        Divider()

                        Button("Move Up") {
                            movePropertyUp(property.dimension)
                        }
                        .disabled(!property.canMoveUp)

                        Button("Move Down") {
                            movePropertyDown(property.dimension)
                        }
                        .disabled(!property.canMoveDown)

                        Divider()

                        Button("Unpin") {
                            unpinProperty(property.dimension)
                        }
                    }
                    .tag(property.dimension)
                    .dropDestination(for: String.self) { dimensions, _ in
                        pinDroppedProperties(dimensions, property.dimension)
                    }
                }
                .onMove(perform: moveProperties)

                if !otherProperties.isEmpty {
                    Section {
                        ForEach(otherProperties) { property in
                            ProjectStatePropertyRow(
                                dimension: property.dimension,
                                displayName: property.displayName,
                                isSelected: selection == property.dimension,
                                membershipAction: .pin,
                                edit: {
                                    editProperty(property.dimension)
                                },
                                updateMembership: {
                                    pinProperty(property.dimension)
                                }
                            )
                            .tag(property.dimension)
                            .draggable(property.dimension)
                            .contextMenu {
                                Button("Edit Display Name…") {
                                    editProperty(property.dimension)
                                }

                                Divider()

                                Button("Pin") {
                                    pinProperty(property.dimension)
                                }
                            }
                        }
                    } header: {
                        Text("Other Properties")
                            .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if properties.isEmpty, otherProperties.isEmpty {
                    ContentUnavailableView(
                        "No Properties",
                        systemImage: "slider.horizontal.3",
                        description: Text("Add a property to show in every bead's inspector.")
                    )
                }
            }
            .accessibilityLabel("State Properties")

            Button("Add Property", action: addProperty)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Add Property")
        }
    }
}

private enum ProjectStatePropertySheet: Identifiable {
    case add
    case edit(String)

    var id: String {
        switch self {
        case .add:
            "add"
        case let .edit(dimension):
            "edit:\(dimension)"
        }
    }
}

private enum ProjectStatePropertyMembershipAction {
    case pin
    case unpin

    var title: String {
        switch self {
        case .pin:
            "Pin"
        case .unpin:
            "Unpin"
        }
    }

    var systemImage: String {
        switch self {
        case .pin:
            "pin"
        case .unpin:
            "minus.circle"
        }
    }

    func rowHelp(dimension: String) -> String {
        switch self {
        case .pin:
            "Select to view values; drag to pin \(dimension)"
        case .unpin:
            "Select to view values; drag to reorder \(dimension)"
        }
    }
}

private struct ProjectStatePropertyRow: View {
    let dimension: String
    let displayName: String
    let isSelected: Bool
    let membershipAction: ProjectStatePropertyMembershipAction
    let edit: () -> Void
    let updateMembership: () -> Void
    @State private var isHovered = false

    private var showsControls: Bool {
        isHovered || isSelected
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .lineLimit(1)

                Text(dimension)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(action: edit) {
                    Label("Edit Display Name…", systemImage: "pencil")
                }

                Divider()

                Button(action: updateMembership) {
                    Label(membershipAction.title, systemImage: membershipAction.systemImage)
                }
            } label: {
                Label("Actions for \(displayName)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(true)
            .help("Actions for \(displayName)")

            Image(systemName: "line.3.horizontal")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .opacity(showsControls ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered in
            if self.isHovered != isHovered {
                self.isHovered = isHovered
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayName), identifier \(dimension)")
        .accessibilityHint("Select to show available values")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Edit Display Name") {
            edit()
        }
        .accessibilityAction(named: membershipAction.title) {
            updateMembership()
        }
        .help(membershipAction.rowHelp(dimension: dimension))
    }
}

private struct ProjectStatePropertyAddSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss
    let addProperty: (String) -> Bool
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ProjectDefinitionAddSheetLayout(
            title: "Add Property",
            description: "Add and pin a state identifier that Beads has not recorded in this project yet.",
            height: 240,
            guidance: BeadStateLabel.dimensionInputRequirement,
            validationMessage: validationMessage,
            isSaving: false,
            canSubmit: canSubmit,
            submitTitle: "Add Property",
            savingAccessibilityLabel: "Adding property",
            cancel: dismiss.callAsFunction,
            submit: pinStateProperty
        ) {
            LabeledContent("Identifier") {
                TextField("phase", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 280)
                    .focused($isNameFocused)
                    .accessibilityLabel("State property identifier")
            }
        }
        .defaultFocus($isNameFocused, true)
    }

    private var normalizedDimension: String? {
        BeadStateLabel.normalizedDimensionInput(name)
    }

    private var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let normalizedDimension else {
            return BeadStateLabel.dimensionInputRequirement
        }
        guard !store.isStateDimensionPinned(normalizedDimension) else {
            return "This state property is already pinned."
        }
        return nil
    }

    private var canSubmit: Bool {
        normalizedDimension != nil && validationMessage == nil
    }

    private func pinStateProperty() {
        guard let normalizedDimension,
              addProperty(normalizedDimension) else {
            return
        }
        dismiss()
    }
}

private struct ProjectStatePropertyEditSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss
    let dimension: String
    let initialDisplayName: String
    private let defaultDisplayName: String
    @State private var displayName: String
    @FocusState private var isDisplayNameFocused: Bool

    init(dimension: String, initialDisplayName: String) {
        self.dimension = dimension
        self.initialDisplayName = initialDisplayName
        defaultDisplayName = BeadStateLabel.displayName(for: dimension)
        _displayName = State(initialValue: initialDisplayName)
    }

    var body: some View {
        ProjectDefinitionAddSheetLayout(
            title: "Edit Property",
            description: "Change the name Beadazzle shows for this project.",
            height: 300,
            guidance: "The bd identifier stays unchanged so existing values and Activity history remain connected.",
            validationMessage: validationMessage,
            isSaving: false,
            canSubmit: canSubmit,
            submitTitle: "Save",
            savingAccessibilityLabel: "Saving property",
            cancel: dismiss.callAsFunction,
            submit: saveDisplayName
        ) {
            LabeledContent("Display Name") {
                HStack(spacing: 8) {
                    TextField(defaultDisplayName, text: $displayName)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($isDisplayNameFocused)
                        .accessibilityLabel("State property display name")

                    Button("Use Default") {
                        displayName = defaultDisplayName
                    }
                    .controlSize(.small)
                    .disabled(normalizedDisplayName == defaultDisplayName)
                }
                .frame(width: 280)
            }

            LabeledContent("Identifier") {
                Text(dimension)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(width: 280, alignment: .leading)
            }
        }
        .defaultFocus($isDisplayNameFocused, true)
    }

    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        guard !normalizedDisplayName.isEmpty else {
            return "Display name is required."
        }
        guard !normalizedDisplayName.contains(where: \Character.isNewline) else {
            return "Display names must fit on one line."
        }
        return nil
    }

    private var canSubmit: Bool {
        validationMessage == nil && normalizedDisplayName != initialDisplayName
    }

    private func saveDisplayName() {
        guard canSubmit,
              store.setStateDimensionDisplayName(normalizedDisplayName, for: dimension) else { return }
        dismiss()
    }
}
