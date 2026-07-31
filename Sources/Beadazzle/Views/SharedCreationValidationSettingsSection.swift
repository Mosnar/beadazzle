import SwiftUI

struct SharedCreationValidationSettingsSection: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        Section {
            switch store.creationValidationLoadState {
            case .idle, .loading:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading shared validation settings…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                LabeledContent("Unavailable") {
                    Button("Try Again", action: reload)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .loaded:
                Toggle(
                    "Require a description",
                    isOn: requiresDescriptionBinding
                )
                .disabled(store.isSavingCreationValidationSettings)

                Picker("When creation validation fails", selection: validationModeBinding) {
                    ForEach(BeadsCreationValidationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(store.isSavingCreationValidationSettings)

                Button("Reload Shared Settings", systemImage: "arrow.clockwise", action: reload)
                    .disabled(store.isSavingCreationValidationSettings)
            }
        } header: {
            Text("Shared Creation Validation")
        } footer: {
            Text("These settings are stored by Beads and apply to every client using this project. Warn allows creation and reports the warning; Error rejects invalid creation.")
        }
        .task(id: store.projectURL) {
            await store.loadCreationValidationSettingsIfNeeded(force: true)
        }
    }

    private var requiresDescriptionBinding: Binding<Bool> {
        Binding {
            store.creationValidationSettings.requiresDescription
        } set: { requiresDescription in
            var settings = store.creationValidationSettings
            settings.requiresDescription = requiresDescription
            Task {
                await store.saveCreationValidationSettings(settings)
            }
        }
    }

    private var validationModeBinding: Binding<BeadsCreationValidationMode> {
        Binding {
            store.creationValidationSettings.mode
        } set: { mode in
            var settings = store.creationValidationSettings
            settings.mode = mode
            Task {
                await store.saveCreationValidationSettings(settings)
            }
        }
    }

    private func reload() {
        Task {
            await store.loadCreationValidationSettingsIfNeeded(force: true)
        }
    }
}
