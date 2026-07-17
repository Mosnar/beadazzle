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
            height: 240,
            guidance: "Use letters, numbers, hyphens, or underscores.",
            validationMessage: validationMessage,
            isSaving: isSaving,
            canSubmit: canSubmit,
            submitTitle: "Add Type",
            savingAccessibilityLabel: "Adding type",
            cancel: dismiss.callAsFunction,
            submit: addType
        ) {
            LabeledContent("Name") {
                TextField("incident", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 280)
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
                // Show the failure inline in this sheet's footer (better for form
                // validation than a modal). Consuming the *most recent* failure — the one
                // this submit just caused — removes it from the shared queue without
                // disturbing older failures the dialog may be presenting.
                saveError = store.consumeMostRecentFailure()?.message ?? "The type could not be added."
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
            height: 280,
            guidance: "Use letters, numbers, hyphens, or underscores.",
            validationMessage: validationMessage,
            isSaving: isSaving,
            canSubmit: canSubmit,
            submitTitle: "Add Status",
            savingAccessibilityLabel: "Adding status",
            cancel: dismiss.callAsFunction,
            submit: addStatus
        ) {
            LabeledContent("Name") {
                TextField("review", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 280)
                    .focused($isNameFocused)
                    .accessibilityLabel("Status name")
            }

            LabeledContent("Category") {
                Picker("Category", selection: $category) {
                    ForEach(BeadStatusCategory.allCases) { category in
                        Label(category.title, systemImage: category.systemImage)
                            .tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
                .accessibilityLabel("Status category")
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
                // Show inline and consume this submit's own (most recent) failure — see
                // ProjectTypeAddSheet.addType.
                saveError = store.consumeMostRecentFailure()?.message ?? "The status could not be added."
                isSaving = false
            }
        }
    }
}

struct ProjectDefinitionAddSheetLayout<Fields: View>: View {
    let title: String
    let description: String
    let height: CGFloat
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 44)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Form {
                Section {
                    fields()
                        .disabled(isSaving)
                } footer: {
                    ProjectDefinitionSheetMessage(
                        guidance: guidance,
                        validationMessage: validationMessage
                    )
                }
            }
            .formStyle(.grouped)
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, 8, for: .scrollContent)

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
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: height)
        .interactiveDismissDisabled(isSaving)
    }
}

private struct ProjectDefinitionSheetMessage: View {
    let guidance: String
    let validationMessage: String?

    var body: some View {
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
