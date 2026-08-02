import SwiftUI

struct BeadsSetupRemoteConfigurationSection: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        @Bindable var model = model

        Section("Task data sync") {
            if let configuredRemote {
                BeadsSetupStatusRow(
                    title: "Current setup",
                    value: configuredRemote.hasReportedProblem
                        ? configuredRemote.status ?? "Needs attention"
                        : "Already configured",
                    kind: configuredRemote.hasReportedProblem ? .warning : .success
                )
                LabeledContent("Remote name", value: configuredRemote.name)
                BeadsSetupLongValue(label: "Remote URL", value: configuredRemote.url)
            } else {
                BeadsSetupLongTextField(
                    label: "Remote name",
                    prompt: "origin",
                    text: $model.draft.remoteName
                )
                BeadsSetupLongTextField(
                    label: "Remote URL",
                    prompt: "Git or Dolt remote URL",
                    text: $model.draft.remoteURL
                )
            }

            Toggle(pushToggleTitle, isOn: $model.draft.completesRemoteSetup)

            if model.draft.profile == .solo {
                Toggle("Allow bd automatic push", isOn: $model.draft.allowsAutomaticPush)
                if let currentAutoPush {
                    Text("Automatic push is currently \(currentAutoPush ? "on" : "off").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Automatic push", value: teamAutoPushSummary)
            }
        }
    }

    private var configuredRemote: BeadsDoltRemote? {
        model.assessment?.remotes?.remotes.first { remote in
            remote.name == model.draft.remoteName
                && BeadsSetupPlanner.normalizedRemote(remote.url)
                    == BeadsSetupPlanner.normalizedRemote(model.draft.remoteURL)
        }
    }

    private var currentAutoPush: Bool? {
        model.assessment?.effectiveBoolConfigValue("dolt.auto-push")
    }

    private var pushToggleTitle: String {
        configuredRemote == nil
            ? "Complete remote setup with an explicit push"
            : "Push local task changes after setup"
    }

    private var teamAutoPushSummary: String {
        switch currentAutoPush {
        case false: "Already off"
        case true: "Will be turned off for team safety"
        case nil: "Will remain off for team safety"
        }
    }
}

struct BeadsSetupHooksConfigurationSection: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        @Bindable var model = model

        Section("Git integration") {
            BeadsSetupStatusRow(
                title: "Current hooks",
                value: statusValue,
                kind: statusKind
            )

            Toggle(toggleTitle, isOn: $model.draft.installsHooks)
                .disabled(model.draft.usesStealthMode)

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hooks: BeadsHooksStatus? {
        model.assessment?.hooks
    }

    private var statusValue: String {
        guard model.assessment?.isInitialized == true else { return "Not installed yet" }
        guard let hooks else { return "Could not inspect" }
        if hooks.allInstalled { return "Installed" }
        if hooks.anyInstalled { return hooks.summary }
        if hooks.hasMissingHooks { return "Not installed" }
        return "Needs review"
    }

    private var statusKind: BeadsSetupStatusKind {
        guard model.assessment?.isInitialized == true else { return .neutral }
        guard let hooks else { return .warning }
        if hooks.allInstalled { return .success }
        if hooks.anyInstalled || !hooks.hasMissingHooks { return .warning }
        return .neutral
    }

    private var toggleTitle: String {
        if hooks?.allInstalled == true { return "Keep bd-managed Git hooks installed" }
        if hooks?.anyInstalled == true { return "Install missing bd-managed Git hooks" }
        return "Install bd-managed Git hooks"
    }

    private var helpText: String {
        if model.draft.usesStealthMode {
            return "Stealth mode keeps bd-managed hooks out of this checkout."
        }
        if hooks?.allInstalled == true {
            return model.draft.installsHooks
                ? "No hook changes are needed."
                : "Setup will remove the hooks managed by bd."
        }
        if hooks?.anyInstalled == true {
            return model.draft.installsHooks
                ? "Setup will install the missing bd-managed hooks."
                : "Setup will remove the hooks currently managed by bd."
        }
        return model.draft.installsHooks
            ? "Setup will install bd-managed hooks in this checkout."
            : "The checkout will keep its current hook setup."
    }
}

struct BeadsSetupBackupConfigurationSection: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        @Bindable var model = model

        Section("Optional backup") {
            if backupIsConfigured {
                BeadsSetupStatusRow(
                    title: "Current backup",
                    value: "Already configured",
                    kind: .success
                )
                if let configuredDestination {
                    BeadsSetupLongValue(label: "Backup destination", value: configuredDestination)
                } else {
                    LabeledContent(
                        "Backup destination",
                        value: model.assessment?.backup?.dolt?.destinationSummary ?? "Configured"
                    )
                }
            } else {
                if model.assessment?.isInitialized == true,
                   model.assessment?.backup == nil {
                    BeadsSetupStatusRow(
                        title: "Current backup",
                        value: "Could not inspect",
                        kind: .warning
                    )
                }
                BeadsSetupLongTextField(
                    label: "Backup destination",
                    prompt: "Filesystem path or backup URL",
                    text: $model.draft.backupDestination
                )
            }

            Toggle(backupToggleTitle, isOn: $model.draft.syncsBackupAfterSetup)
                .disabled(!backupIsConfigured && model.draft.backupDestination.nilIfBlank == nil)
        }
    }

    private var configuredDestination: String? {
        guard backupIsConfigured else { return nil }
        return model.assessment?.backup?.dolt?.backupURL?.nilIfBlank
    }

    private var backupIsConfigured: Bool {
        model.assessment?.backup?.isConfigured == true
    }

    private var backupToggleTitle: String {
        backupIsConfigured ? "Sync this backup after setup" : "Create the backup after setup"
    }
}

private struct BeadsSetupLongTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BeadsSetupLongValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum BeadsSetupStatusKind {
    case success
    case warning
    case neutral
}

private struct BeadsSetupStatusRow: View {
    let title: String
    let value: String
    let kind: BeadsSetupStatusKind

    var body: some View {
        LabeledContent(title) {
            Label(value, systemImage: systemImage)
                .foregroundStyle(color)
        }
    }

    private var systemImage: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "circle"
        }
    }

    private var color: Color {
        switch kind {
        case .success: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}
