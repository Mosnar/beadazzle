import SwiftUI

struct NewBeadAssigneePreferenceControl: View {
    @Binding var preference: NewBeadAssigneePreference
    let availableAssignees: [String]

    var body: some View {
        Picker("Default assignee", selection: modeBinding) {
            ForEach(NewBeadAssigneePreference.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        if preference.mode == .specific {
            SpecificAssigneeSettingsField(
                assignee: specificValueBinding,
                availableAssignees: availableAssignees
            )
        }
    }

    private var modeBinding: Binding<NewBeadAssigneePreference.Mode> {
        Binding {
            preference.mode
        } set: { mode in
            switch mode {
            case .unassigned:
                preference = .unassigned
            case .owner:
                preference = .owner
            case .specific:
                preference = .specific(preference.specificValue)
            }
        }
    }

    private var specificValueBinding: Binding<String> {
        Binding {
            preference.specificValue
        } set: { value in
            preference = .specific(value)
        }
    }
}

struct ProjectNewBeadAssigneePreferenceControl: View {
    @Binding var override: NewBeadAssigneePreference?
    let appDefault: NewBeadAssigneePreference
    let availableAssignees: [String]

    var body: some View {
        Picker("Default assignee", selection: modeBinding) {
            Text("Use App Default (\(appDefault.normalized.displayName))")
                .tag(ProjectOverrideMode.inherit)
            Text("Unassigned").tag(ProjectOverrideMode.unassigned)
            Text("Owner").tag(ProjectOverrideMode.owner)
            Text("Specific Assignee").tag(ProjectOverrideMode.specific)
        }

        if override?.mode == .specific {
            SpecificAssigneeSettingsField(
                assignee: specificValueBinding,
                availableAssignees: availableAssignees
            )
        }
    }

    private var modeBinding: Binding<ProjectOverrideMode> {
        Binding {
            guard let override else { return .inherit }
            switch override.mode {
            case .unassigned:
                return .unassigned
            case .owner:
                return .owner
            case .specific:
                return .specific
            }
        } set: { mode in
            switch mode {
            case .inherit:
                override = nil
            case .unassigned:
                override = .unassigned
            case .owner:
                override = .owner
            case .specific:
                override = .specific(override?.specificValue ?? "")
            }
        }
    }

    private var specificValueBinding: Binding<String> {
        Binding {
            override?.specificValue ?? ""
        } set: { value in
            override = .specific(value)
        }
    }
}

private enum ProjectOverrideMode: String, Hashable {
    case inherit
    case unassigned
    case owner
    case specific
}

private struct SpecificAssigneeSettingsField: View {
    @Binding var assignee: String
    let availableAssignees: [String]

    private var suggestions: [String] {
        let query = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        return availableAssignees.lazy
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        LabeledContent("Assignee") {
            HStack(spacing: 6) {
                TextField("Name or email", text: $assignee)
                    .frame(maxWidth: 320)

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                assignee = suggestion
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose an assignee used in this project")
                    .accessibilityLabel("Assignee suggestions")
                }
            }
        }
    }
}
