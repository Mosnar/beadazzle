import SwiftUI

struct ProjectIssueTextSectionSettings: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        Form {
            Section {
                Picker("Empty sections", selection: projectVisibilityModeBinding) {
                    Text("Use App Default (\(store.issueTextSectionVisibilityMode.title))")
                        .tag(IssueTextSectionVisibilityMode?.none)
                    ForEach(IssueTextSectionVisibilityMode.allCases) { mode in
                        Text(mode.title).tag(Optional(mode))
                    }
                }

                Picker("Section order", selection: usesCustomOrderBinding) {
                    Text("Use App Default").tag(false)
                    Text("Custom Order").tag(true)
                }

                if let orderBinding = projectOrderBinding {
                    IssueTextSectionOrderControl(order: orderBinding)
                }
            } header: {
                Text("Editor Defaults")
            } footer: {
                Text("These preferences are private to this Mac and apply only to the active project.")
            }

            Section {
                ProjectIssueTextSectionSuggestionMatrixControl(
                    typeNames: store.configurableMutableTypes
                )
            } header: {
                Text("Suggested Sections by Type")
            } footer: {
                Text("Each type can inherit its app setting or define a project-specific set of initially visible empty fields.")
            }

            SharedCreationValidationSettingsSection()

            Section {
                Button("Reset All Editor Overrides") {
                    store.resetProjectIssueTextSectionOverrides()
                }
                .disabled(store.projectIssueTextSectionOverrides.isEmpty)
            }
        }
        .settingsGroupedForm()
    }

    private var projectVisibilityModeBinding: Binding<IssueTextSectionVisibilityMode?> {
        Binding {
            store.projectIssueTextSectionVisibilityModeOverride
        } set: { mode in
            store.projectIssueTextSectionVisibilityModeOverride = mode
        }
    }

    private var usesCustomOrderBinding: Binding<Bool> {
        Binding {
            store.projectIssueTextSectionOrderOverride != nil
        } set: { usesCustom in
            store.projectIssueTextSectionOrderOverride = usesCustom
                ? store.effectiveIssueTextSectionPreferences.order
                : nil
        }
    }

    private var projectOrderBinding: Binding<[IssueTextSection]>? {
        guard store.projectIssueTextSectionOrderOverride != nil else { return nil }
        return Binding {
            store.projectIssueTextSectionOrderOverride ?? store.issueTextSectionOrder
        } set: { order in
            store.projectIssueTextSectionOrderOverride = order
        }
    }
}
