import SwiftUI

struct IssueTextSectionEditorSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                Picker("Empty sections", selection: $store.issueTextSectionVisibilityMode) {
                    ForEach(IssueTextSectionVisibilityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Visibility")
            } footer: {
                Text("Sections containing text always remain visible. Hidden empty sections can still be added while editing.")
            }

            Section {
                IssueTextSectionSuggestionMatrixControl(
                    rows: IssueTextSectionSuggestionMatrix.builtInTypeNames + [
                        IssueTextSectionSuggestionMatrix.otherTypesKey
                    ],
                    sections: { type in
                        store.appSuggestedSections(for: type)
                    },
                    setSections: { sections, type in
                        store.setAppSuggestedSections(sections, for: type)
                    }
                )

                Button("Restore Beads Suggestions") {
                    store.resetAppIssueTextSectionSuggestions()
                }
                .disabled(store.issueTextSectionSuggestions == .beadsDefault)
            } header: {
                Text("Suggested Sections by Type")
            } footer: {
                Text("These choices control which empty fields appear initially; they do not change Beads validation rules.")
            }

            Section {
                IssueTextSectionOrderControl(order: $store.issueTextSectionOrder)

                Button("Restore Default Order") {
                    store.resetAppIssueTextSectionOrder()
                }
                .disabled(store.issueTextSectionOrder == IssueTextSection.canonicalOrder)
            } header: {
                Text("Section Order")
            } footer: {
                Text("The same order is used for new beads, bead details, and Find Next or Previous.")
            }
        }
        .settingsGroupedForm()
    }
}
