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
    private var project: BeadProjectStore { store.project }
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
        ProjectSettingsPane(rawValue: selectedPaneRawValue) ?? .storage
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
        guard let projectURL, let activeProjectURL = project.projectURL else { return false }
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
            Section {
                LabeledContent("Consider stale after") {
                    Stepper(value: $store.staleCutoffDays, in: 1...365) {
                        Text("\(store.staleCutoffDays.formatted()) days")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Staleness")
            } footer: {
                Text("Controls which open beads appear in the Stale sidebar view.")
            }

            Section {
                Toggle("Hide parents whose unfinished children are all blocked", isOn: $store.hidesParentsWithOnlyBlockedChildrenInReady)
            } header: {
                Text("Ready")
            } footer: {
                Text("Keeps blocked parent work out of Ready when none of its unfinished children can move forward.")
            }
        }
        .settingsGroupedForm()
    }
}

private struct ProjectTypesSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var isAddingType = false
    @State private var pendingDeleteName: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.allTypeDefinitions) { definition in
                    ProjectDefinitionRow(
                        name: definition.name,
                        detail: definition.description,
                        source: definition.source,
                        systemImage: "tag",
                        isVisible: !store.isTypeHidden(definition.name),
                        canDelete: definition.isCustom
                    ) { isVisible in
                        store.setType(definition.name, isHidden: !isVisible)
                    } delete: {
                        pendingDeleteName = definition.name
                    }
                }
            } header: {
                ProjectDefinitionSectionHeader(
                    title: "Types",
                    addTitle: "Add Type…",
                    isPresentingAddSheet: $isAddingType
                )
            }
        }
        .settingsGroupedForm()
        .sheet(isPresented: $isAddingType) {
            ProjectTypeAddSheet()
        }
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

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteName != nil },
            set: { if !$0 { pendingDeleteName = nil } }
        )
    }
}

private struct ProjectStatusesSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var isAddingStatus = false
    @State private var pendingDeleteName: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.allStatusDefinitions) { definition in
                    ProjectDefinitionRow(
                        name: definition.name,
                        detail: definition.category.title,
                        source: definition.source,
                        systemImage: definition.category.systemImage,
                        isVisible: !store.isStatusHidden(definition.name),
                        canDelete: definition.isCustom
                    ) { isVisible in
                        store.setStatus(definition.name, isHidden: !isVisible)
                    } delete: {
                        pendingDeleteName = definition.name
                    }
                }
            } header: {
                ProjectDefinitionSectionHeader(
                    title: "Statuses",
                    addTitle: "Add Status…",
                    isPresentingAddSheet: $isAddingStatus
                )
            }
        }
        .settingsGroupedForm()
        .sheet(isPresented: $isAddingStatus) {
            ProjectStatusAddSheet()
        }
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

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteName != nil },
            set: { if !$0 { pendingDeleteName = nil } }
        )
    }
}

private struct ProjectDefinitionRow: View {
    let name: String
    let detail: String?
    let source: BeadDefinitionSource
    let systemImage: String
    let isVisible: Bool
    let canDelete: Bool
    let setVisibility: (Bool) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .foregroundStyle(isVisible ? .primary : .secondary)
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

            Toggle(
                "Visible in Beadazzle",
                isOn: Binding(get: { isVisible }, set: setVisibility)
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(isVisible ? "Hide \(name) in Beadazzle" : "Show \(name) in Beadazzle")
            .accessibilityLabel("\(name) visible in Beadazzle")

            if canDelete {
                Menu {
                    Button("Delete \(name)…", role: .destructive, action: delete)
                } label: {
                    Label("Actions for \(name)", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Actions for \(name)")
            }
        }
        .contentShape(Rectangle())
    }
}
