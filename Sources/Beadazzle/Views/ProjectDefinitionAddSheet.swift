import SwiftUI

struct ProjectDefinitionSectionHeader: View {
    let title: String
    let addTitle: String
    @Binding var isPresentingAddSheet: Bool

    var body: some View {
        HStack {
            Text(title)

            Spacer()

            Button(addTitle, systemImage: "plus") {
                isPresentingAddSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct ProjectTypeAddSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ProjectDefinitionAddSheetLayout(
            title: "Add Type",
            description: "Create a custom issue type for this project.",
            systemImage: "tag.fill",
            guidance: "Use letters, numbers, hyphens, or underscores.",
            validationMessage: validationMessage,
            isSaving: isSaving,
            canSubmit: canSubmit,
            submitTitle: "Add Type",
            savingAccessibilityLabel: "Adding type",
            cancel: dismiss.callAsFunction,
            submit: addType
        ) {
            ProjectDefinitionSheetField(title: "Name") {
                TextField("Type name", text: $name, prompt: Text("incident"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .accessibilityLabel("Type name")
            }
        }
        .defaultFocus($isNameFocused, true)
        .onChange(of: name) {
            saveError = nil
        }
    }

    private var normalizedName: String? {
        try? WorkflowValueValidator.normalizedIdentifier(name)
    }

    private var validationMessage: String? {
        if let saveError {
            return saveError
        }

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let normalizedName else {
            return "Names must start with a letter or number and contain only letters, numbers, hyphens, or underscores."
        }
        guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(normalizedName) else {
            return BeadIssueWorkflowPolicy.reservedIssueTypeError
        }
        guard store.allTypeDefinitions.allSatisfy({ $0.name != normalizedName }) else {
            return "A type named \(normalizedName) already exists."
        }
        return nil
    }

    private var canSubmit: Bool {
        normalizedName != nil && validationMessage == nil && !isSaving
    }

    private func addType() {
        guard canSubmit else { return }
        let submittedName = name
        isSaving = true
        saveError = nil

        Task {
            if await store.addCustomType(named: submittedName) {
                dismiss()
            } else {
                saveError = store.lastError ?? "The type could not be added."
                isSaving = false
            }
        }
    }
}

struct ProjectStatusAddSheet: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = BeadStatusCategory.active
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        ProjectDefinitionAddSheetLayout(
            title: "Add Status",
            description: "Create a custom workflow status for this project.",
            systemImage: "circle.lefthalf.filled",
            guidance: "Use letters, numbers, hyphens, or underscores.",
            validationMessage: validationMessage,
            isSaving: isSaving,
            canSubmit: canSubmit,
            submitTitle: "Add Status",
            savingAccessibilityLabel: "Adding status",
            cancel: dismiss.callAsFunction,
            submit: addStatus
        ) {
            VStack(spacing: 12) {
                ProjectDefinitionSheetField(title: "Name") {
                    TextField("Status name", text: $name, prompt: Text("review"))
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .accessibilityLabel("Status name")
                }

                ProjectDefinitionSheetField(title: "Category") {
                    Picker("Category", selection: $category) {
                        ForEach(BeadStatusCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Status category")
                }
            }
        }
        .defaultFocus($isNameFocused, true)
        .onChange(of: name) {
            saveError = nil
        }
    }

    private var normalizedName: String? {
        try? WorkflowValueValidator.normalizedIdentifier(name)
    }

    private var validationMessage: String? {
        if let saveError {
            return saveError
        }

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let normalizedName else {
            return "Names must start with a letter or number and contain only letters, numbers, hyphens, or underscores."
        }
        guard store.allStatusDefinitions.allSatisfy({ $0.name != normalizedName }) else {
            return "A status named \(normalizedName) already exists."
        }
        return nil
    }

    private var canSubmit: Bool {
        normalizedName != nil && validationMessage == nil && !isSaving
    }

    private func addStatus() {
        guard canSubmit else { return }
        let submittedName = name
        let submittedCategory = category
        isSaving = true
        saveError = nil

        Task {
            if await store.addCustomStatus(named: submittedName, category: submittedCategory) {
                dismiss()
            } else {
                saveError = store.lastError ?? "The status could not be added."
                isSaving = false
            }
        }
    }
}

private struct ProjectDefinitionAddSheetLayout<Fields: View>: View {
    let title: String
    let description: String
    let systemImage: String
    let guidance: String
    let validationMessage: String?
    let isSaving: Bool
    let canSubmit: Bool
    let submitTitle: String
    let savingAccessibilityLabel: String
    let cancel: () -> Void
    let submit: () -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(.quaternary, in: .rect(cornerRadius: 9))

                        Text(title)
                            .font(.title2.weight(.semibold))
                    }

                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    fields()
                        .disabled(isSaving)

                    Group {
                        if let validationMessage {
                            Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        } else {
                            Text(guidance)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 28)

            Divider()

            HStack(spacing: 10) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(savingAccessibilityLabel)
                }

                Spacer()

                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)

                Button(submitTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
        }
        .frame(width: 520)
        .interactiveDismissDisabled(isSaving)
    }
}

private struct ProjectDefinitionSheetField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .fontWeight(.medium)

            Spacer(minLength: 20)

            content()
                .frame(width: 280)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
    }
}
