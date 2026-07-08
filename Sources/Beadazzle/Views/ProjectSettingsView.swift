import SwiftUI

private enum ProjectSettingsPane: String, CaseIterable, Identifiable, Hashable {
    case storage
    case workflow
    case types
    case statuses

    var id: Self { self }

    var title: String {
        switch self {
        case .storage:
            "Storage"
        case .workflow:
            "Workflow"
        case .types:
            "Types"
        case .statuses:
            "Statuses"
        }
    }

    var systemImage: String {
        switch self {
        case .storage:
            "externaldrive"
        case .workflow:
            "checklist"
        case .types:
            "tag"
        case .statuses:
            "circle.lefthalf.filled"
        }
    }
}

struct ProjectSettingsView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let projectURL: URL?

    @SceneStorage("Beadazzle.ProjectSettings.SelectedPane") private var selectedPaneRawValue = ProjectSettingsPane.storage.rawValue

    private var selectedPane: Binding<ProjectSettingsPane> {
        Binding {
            activePane
        } set: { pane in
            selectedPaneRawValue = pane.rawValue
        }
    }

    private var activePane: ProjectSettingsPane {
        ProjectSettingsPane(rawValue: selectedPaneRawValue) ?? .types
    }

    var body: some View {
        SettingsPaneContainer(
            panes: Array(ProjectSettingsPane.allCases),
            selection: selectedPane,
            title: \.title,
            minDetailWidth: 560,
            minHeight: 500
        ) { pane in
            Label(pane.title, systemImage: pane.systemImage)
        } detail: { pane in
            ProjectSettingsDetail(pane: pane, isActiveProject: isActiveProject)
        }
    }

    private var isActiveProject: Bool {
        guard let projectURL, let activeProjectURL = store.projectURL else { return false }
        return projectURL.standardizedFileURL.path == activeProjectURL.standardizedFileURL.path
    }
}

private struct ProjectSettingsDetail: View {
    let pane: ProjectSettingsPane
    let isActiveProject: Bool

    var body: some View {
        if isActiveProject {
            switch pane {
            case .storage:
                ProjectStorageSettingsPane()
            case .workflow:
                ProjectWorkflowSettingsPane()
            case .types:
                ProjectTypesSettingsPane()
            case .statuses:
                ProjectStatusesSettingsPane()
            }
        } else {
            ContentUnavailableView("Active Project Required", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProjectWorkflowSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Ready") {
                Toggle("Hide parents whose unfinished children are all blocked", isOn: $store.hidesParentsWithOnlyBlockedChildrenInReady)
            }
        }
        .settingsGroupedForm()
    }
}

private struct ProjectTypesSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var newTypeName = ""
    @State private var pendingDeleteName: String?

    var body: some View {
        Form {
            Section("Add Type") {
                LabeledContent("Name") {
                    HStack(spacing: 8) {
                        TextField("New type", text: $newTypeName)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 200)
                            .onSubmit(addType)

                        Button("Add", systemImage: "plus") {
                            addType()
                        }
                        .disabled(!canAddType)
                    }
                }
            }

            Section("Types") {
                ForEach(store.allTypeDefinitions) { definition in
                    ProjectDefinitionRow(
                        name: definition.name,
                        detail: definition.description,
                        source: definition.source,
                        systemImage: "tag",
                        isHidden: store.isTypeHidden(definition.name),
                        canDelete: definition.isCustom
                    ) {
                        store.setType(definition.name, isHidden: !store.isTypeHidden(definition.name))
                    } delete: {
                        pendingDeleteName = definition.name
                    }
                }
            }
        }
        .settingsGroupedForm()
        .confirmationDialog(
            "Delete custom type?",
            isPresented: deleteBinding,
            presenting: pendingDeleteName
        ) { name in
            Button("Delete \(name)", role: .destructive) {
                Task {
                    await store.deleteCustomType(named: name)
                }
            }
        }
    }

    private var canAddType: Bool {
        guard let normalizedName = try? WorkflowValueValidator.normalizedIdentifier(newTypeName) else { return false }
        return BeadIssueWorkflowPolicy.isNormalMutableIssueType(normalizedName)
            && store.allTypeDefinitions.allSatisfy { $0.name != normalizedName }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteName != nil },
            set: { if !$0 { pendingDeleteName = nil } }
        )
    }

    private func addType() {
        guard canAddType else { return }
        Task {
            if await store.addCustomType(named: newTypeName) {
                newTypeName = ""
            }
        }
    }
}

private struct ProjectStatusesSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var newStatusName = ""
    @State private var newStatusCategory = BeadStatusCategory.active
    @State private var pendingDeleteName: String?

    var body: some View {
        Form {
            Section("Add Status") {
                LabeledContent("Name") {
                    HStack(spacing: 8) {
                        TextField("New status", text: $newStatusName)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 200)
                            .onSubmit(addStatus)

                        Button("Add", systemImage: "plus") {
                            addStatus()
                        }
                        .disabled(!canAddStatus)
                    }
                }

                Picker("Category", selection: $newStatusCategory) {
                    ForEach(BeadStatusCategory.allCases) { category in
                        Label(category.title, systemImage: category.systemImage)
                            .tag(category)
                    }
                }
            }

            Section("Statuses") {
                ForEach(store.allStatusDefinitions) { definition in
                    ProjectDefinitionRow(
                        name: definition.name,
                        detail: definition.category.title,
                        source: definition.source,
                        systemImage: definition.category.systemImage,
                        isHidden: store.isStatusHidden(definition.name),
                        canDelete: definition.isCustom
                    ) {
                        store.setStatus(definition.name, isHidden: !store.isStatusHidden(definition.name))
                    } delete: {
                        pendingDeleteName = definition.name
                    }
                }
            }
        }
        .settingsGroupedForm()
        .confirmationDialog(
            "Delete custom status?",
            isPresented: deleteBinding,
            presenting: pendingDeleteName
        ) { name in
            Button("Delete \(name)", role: .destructive) {
                Task {
                    await store.deleteCustomStatus(named: name)
                }
            }
        }
    }

    private var canAddStatus: Bool {
        guard let normalizedName = try? WorkflowValueValidator.normalizedIdentifier(newStatusName) else { return false }
        return store.allStatusDefinitions.allSatisfy { $0.name != normalizedName }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteName != nil },
            set: { if !$0 { pendingDeleteName = nil } }
        )
    }

    private func addStatus() {
        guard canAddStatus else { return }
        Task {
            if await store.addCustomStatus(named: newStatusName, category: newStatusCategory) {
                newStatusName = ""
            }
        }
    }
}

private struct ProjectDefinitionRow: View {
    let name: String
    let detail: String?
    let source: BeadDefinitionSource
    let systemImage: String
    let isHidden: Bool
    let canDelete: Bool
    let toggleVisibility: () -> Void
    let delete: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(isHidden ? .secondary : .primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(source.title)

                        if let detail, !detail.isEmpty {
                            Text(detail)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            Spacer(minLength: 12)

            if isHidden {
                Text("Hidden")
                    .foregroundStyle(.secondary)
            }

            Button {
                toggleVisibility()
            } label: {
                Label(isHidden ? "Show in Beadazzle" : "Hide in Beadazzle", systemImage: isHidden ? "eye.slash" : "eye")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .opacity(actionsAreVisible ? 1 : 0)
            .allowsHitTesting(actionsAreVisible)
            .accessibilityHidden(!actionsAreVisible)
            .help(isHidden ? "Show in Beadazzle" : "Hide in Beadazzle")

            if canDelete {
                Button(role: .destructive) {
                    delete()
                } label: {
                    Label("Delete custom value", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .opacity(actionsAreVisible ? 1 : 0)
                .allowsHitTesting(actionsAreVisible)
                .accessibilityHidden(!actionsAreVisible)
                .help("Delete custom value")
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
    }

    private var actionsAreVisible: Bool {
        isHovered || isFocused
    }
}
