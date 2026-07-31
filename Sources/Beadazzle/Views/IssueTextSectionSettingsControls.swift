import SwiftUI

struct IssueTextSectionSuggestionMatrixControl: View {
    let rows: [String]
    let sections: (String) -> Set<IssueTextSection>
    let setSections: (Set<IssueTextSection>, String) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Text("Type")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Sections")
                    .frame(minWidth: 260, alignment: .leading)
            }
            .suggestionTableHeader()

            ForEach(rows, id: \.self) { type in
                GridRow {
                    Text(displayName(for: type))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    IssueTextSectionSelectionMenu(
                        typeName: displayName(for: type),
                        sections: sections(type),
                        setSections: { setSections($0, type) }
                    )
                }
            }
        }
    }

    private func displayName(for type: String) -> String {
        if type == IssueTextSectionSuggestionMatrix.otherTypesKey {
            "Other Types"
        } else {
            type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct ProjectIssueTextSectionSuggestionMatrixControl: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let typeNames: [String]

    var body: some View {
        if typeNames.isEmpty {
            ContentUnavailableView(
                "No Bead Types",
                systemImage: "tag",
                description: Text("Type definitions are not available for this project.")
            )
        } else {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Text("Type")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Source")
                        .frame(minWidth: 140, alignment: .leading)
                    Text("Sections")
                        .frame(minWidth: 260, alignment: .leading)
                }
                .suggestionTableHeader()

                ForEach(typeNames, id: \.self) { type in
                    GridRow {
                        Text(typeDisplayName(type))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Picker(
                            "Source for \(typeDisplayName(type))",
                            selection: overrideModeBinding(for: type)
                        ) {
                            Text("Use App Default").tag(false)
                            Text("Custom").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 140, alignment: .leading)
                        .accessibilityLabel("Source for \(typeDisplayName(type))")

                        if store.projectSuggestedSectionOverride(for: type) != nil {
                            IssueTextSectionSelectionMenu(
                                typeName: typeDisplayName(type),
                                sections: effectiveSections(for: type),
                                setSections: {
                                    store.setProjectSuggestedSectionOverride($0, for: type)
                                }
                            )
                        } else {
                            Text(IssueTextSectionSelectionSummary.title(
                                for: effectiveSections(for: type)
                            ))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 260, alignment: .leading)
                            .accessibilityLabel("Sections for \(typeDisplayName(type))")
                            .accessibilityValue(
                                IssueTextSectionSelectionSummary.accessibilityValue(
                                    for: effectiveSections(for: type)
                                )
                            )
                            .help("Inherited from App Settings")
                        }
                    }
                }
            }
        }
    }

    private func overrideModeBinding(for type: String) -> Binding<Bool> {
        Binding {
            store.projectSuggestedSectionOverride(for: type) != nil
        } set: { isCustom in
            store.setProjectSuggestedSectionOverride(
                isCustom ? store.appIssueTextSectionPreferences.suggestions.sections(for: type) : nil,
                for: type
            )
        }
    }

    private func effectiveSections(for type: String) -> Set<IssueTextSection> {
        store.projectSuggestedSectionOverride(for: type)
            ?? store.appIssueTextSectionPreferences.suggestions.sections(for: type)
    }

    private func typeDisplayName(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct IssueTextSectionSelectionMenu: View {
    let typeName: String
    let sections: Set<IssueTextSection>
    let setSections: (Set<IssueTextSection>) -> Void

    var body: some View {
        Menu {
            ForEach(IssueTextSection.canonicalOrder) { section in
                Toggle(section.title, isOn: sectionBinding(section))
            }
        } label: {
            Text(IssueTextSectionSelectionSummary.title(for: sections))
                .lineLimit(1)
                .frame(minWidth: 260, alignment: .leading)
        }
        .menuStyle(.button)
        .accessibilityLabel("Sections for \(typeName)")
        .accessibilityValue(IssueTextSectionSelectionSummary.accessibilityValue(for: sections))
        .help("Choose the sections suggested for \(typeName)")
    }

    private func sectionBinding(_ section: IssueTextSection) -> Binding<Bool> {
        Binding {
            sections.contains(section)
        } set: { isIncluded in
            var updated = sections
            if isIncluded {
                updated.insert(section)
            } else {
                updated.remove(section)
            }
            setSections(updated)
        }
    }
}

private enum IssueTextSectionSelectionSummary {
    static func title(for sections: Set<IssueTextSection>) -> String {
        if sections.isEmpty {
            "No Sections"
        } else if sections.count == IssueTextSection.canonicalOrder.count {
            "All Sections"
        } else {
            orderedTitles(for: sections).joined(separator: ", ")
        }
    }

    static func accessibilityValue(for sections: Set<IssueTextSection>) -> String {
        if sections.isEmpty {
            "No sections selected"
        } else {
            orderedTitles(for: sections).joined(separator: ", ")
        }
    }

    private static func orderedTitles(for sections: Set<IssueTextSection>) -> [String] {
        IssueTextSection.canonicalOrder
            .filter(sections.contains)
            .map(\.title)
    }
}

private extension View {
    func suggestionTableHeader() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct IssueTextSectionOrderControl: View {
    @Binding var order: [IssueTextSection]

    var body: some View {
        List {
            ForEach(order) { section in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(section.title)
                    Spacer()
                    Button {
                        move(section, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMove(section, by: -1))
                    .help("Move \(section.title) up")
                    .accessibilityLabel("Move \(section.title) up")

                    Button {
                        move(section, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMove(section, by: 1))
                    .help("Move \(section.title) down")
                    .accessibilityLabel("Move \(section.title) down")
                }
                .contextMenu {
                    Button("Move Up") {
                        move(section, by: -1)
                    }
                    .disabled(!canMove(section, by: -1))

                    Button("Move Down") {
                        move(section, by: 1)
                    }
                    .disabled(!canMove(section, by: 1))
                }
            }
            .onMove(perform: move)
        }
        .frame(height: 150)
        .accessibilityLabel("Bead content section order")
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var updated = order
        updated.move(fromOffsets: offsets, toOffset: destination)
        order = IssueTextSectionPreferences.normalizedOrder(updated)
    }

    private func canMove(_ section: IssueTextSection, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: section) else { return false }
        return order.indices.contains(index + offset)
    }

    private func move(_ section: IssueTextSection, by offset: Int) {
        guard let index = order.firstIndex(of: section),
              order.indices.contains(index + offset)
        else { return }
        var updated = order
        updated.swapAt(index, index + offset)
        order = updated
    }
}
