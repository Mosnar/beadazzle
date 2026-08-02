import Observation
import SwiftUI

struct BeadsSetupRequest: Identifiable {
    let id = UUID()
    let projectURL: URL
    var initialIntent: BeadsSetupIntent? = nil
}

struct BeadsSetupWizard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BeadStore.self) private var store
    let request: BeadsSetupRequest

    @State private var model: BeadsSetupWizardModel

    init(request: BeadsSetupRequest) {
        self.request = request
        _model = State(initialValue: BeadsSetupWizardModel(
            projectURL: request.projectURL,
            initialIntent: request.initialIntent
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BeadsSetupStepList(currentStep: model.step)
                    .frame(width: 175)
                    .frame(maxHeight: .infinity)
                    .background(.quaternary.opacity(0.35))

                Divider()

                Group {
                    switch model.step {
                    case .inspect:
                        BeadsSetupInspectStep(model: model)
                    case .useCase:
                        BeadsSetupUseCaseStep(model: model)
                    case .configure:
                        BeadsSetupConfigureStep(model: model)
                    case .review:
                        BeadsSetupReviewStep(model: model)
                    case .results:
                        BeadsSetupResultsStep(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()
            BeadsSetupWizardButtons(model: model, dismiss: dismiss)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
        .interactiveDismissDisabled(model.isApplying)
        .task(id: request.projectURL) {
            await model.inspect(using: store)
        }
    }
}

@MainActor
@Observable
final class BeadsSetupWizardModel {
    enum Step: Int, CaseIterable {
        case inspect
        case useCase
        case configure
        case review
        case results

        var title: String {
            switch self {
            case .inspect: "Inspect"
            case .useCase: "Use Case"
            case .configure: "Configure"
            case .review: "Review"
            case .results: "Results"
            }
        }
    }

    let projectURL: URL
    let initialIntent: BeadsSetupIntent?
    var step = Step.inspect
    var assessment: BeadsSetupAssessment? {
        didSet { refreshPlan() }
    }
    var draft = BeadsSetupDraft() {
        didSet { refreshPlan() }
    }
    var useCaseAnswers: BeadsSetupUseCaseAnswers
    var isInspecting = false
    var isApplying = false
    var failure: BeadsSetupFailurePresentation?
    var report: BeadsSetupApplyReport?
    private(set) var plan: BeadsSetupPlan?

    init(projectURL: URL, initialIntent: BeadsSetupIntent?) {
        self.projectURL = projectURL
        self.initialIntent = initialIntent
        useCaseAnswers = initialIntent?.useCaseAnswers
            ?? BeadsSetupUseCaseAnswers(profile: initialIntent?.profile)
        if let initialIntent {
            draft.profile = initialIntent.profile
            draft.useCaseAnswers = useCaseAnswers
        }
        refreshPlan()
    }

    var canContinue: Bool {
        switch step {
        case .inspect:
            assessment != nil && !isInspecting
        case .useCase:
            useCaseAnswers.resolvedProfile != nil
        case .configure:
            plan?.blockingFindings.isEmpty == true
        case .review:
            plan?.canApply == true && !isApplying
        case .results:
            true
        }
    }

    func inspect(using store: BeadStore) async {
        guard assessment == nil, !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }
        failure = nil
        do {
            let assessment = try await store.inspectBeadsSetup(projectURL: projectURL)
            guard !Task.isCancelled else { return }
            self.assessment = assessment
            draft.applyProfileDefaults(initialIntent?.profile ?? suggestedProfile(for: assessment), assessment: assessment)
            if let remoteName = initialIntent?.remoteName {
                draft.remoteName = remoteName
                draft.remoteURL = assessment.remotes?.remotes
                    .first(where: { $0.name == remoteName })?.url ?? ""
            }
            draft.installsHooks = initialIntent?.installsHooks
                ?? (assessment.isInitialized ? assessment.hooks?.anyInstalled ?? true : true)
            draft.allowsAutomaticPush = initialIntent?.allowsAutomaticPush
                ?? (assessment.effectiveBoolConfigValue("dolt.auto-push") == true)
            draft.backupDestination = assessment.backup?.dolt?.backupURL ?? ""
            step = .useCase
        } catch is CancellationError {
            return
        } catch {
            failure = .inspection(error)
        }
    }

    func selectProjectRelationship(_ relationship: BeadsSetupProjectRelationship) {
        updateUseCaseAnswers { $0.selectProjectRelationship(relationship) }
    }

    func selectCollaborationStyle(_ style: BeadsSetupCollaborationStyle) {
        updateUseCaseAnswers { $0.selectCollaborationStyle(style) }
    }

    func selectProjectTrackerSharing(_ usesSharedTracker: Bool) {
        updateUseCaseAnswers { $0.selectProjectTrackerSharing(usesSharedTracker) }
    }

    func selectTeamSharing(_ sharesTracker: Bool) {
        updateUseCaseAnswers { $0.selectTeamSharing(sharesTracker) }
    }

    func selectGitSync(_ syncsThroughGit: Bool) {
        updateUseCaseAnswers { $0.selectGitSync(syncsThroughGit) }
    }

    func selectAdvancedSetup() {
        updateUseCaseAnswers { $0.selectAdvancedSetup() }
    }

    func startGuidedSetup() {
        useCaseAnswers = BeadsSetupUseCaseAnswers()
        draft.useCaseAnswers = useCaseAnswers
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1), step != .results else { return }
        step = previous
        failure = nil
    }

    func continueForward() {
        guard canContinue, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        failure = nil
    }

    func prepareReview(using store: BeadStore) async {
        guard step == .configure, !isInspecting else { return }
        isInspecting = true
        defer { isInspecting = false }
        failure = nil
        do {
            let refreshedAssessment = try await inspectCurrentDraft(using: store)
            guard !Task.isCancelled else { return }
            assessment = refreshedAssessment
            guard plan?.canApply == true else { return }
            step = .review
        } catch is CancellationError {
            return
        } catch {
            failure = .inspection(error)
        }
    }

    func apply(using store: BeadStore) async {
        guard let assessment, plan?.canApply == true, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        failure = nil
        do {
            report = try await store.applyBeadsSetup(draft: draft, assessment: assessment)
            step = .results
        } catch is CancellationError {
            return
        } catch {
            if let failure = error as? BeadsSetupApplyFailure {
                report = failure.report
            }
            failure = .applying(error)
            if let refreshedAssessment = try? await inspectCurrentDraft(using: store),
               !Task.isCancelled {
                self.assessment = refreshedAssessment
            }
        }
    }

    private func inspectCurrentDraft(using store: BeadStore) async throws -> BeadsSetupAssessment {
        let candidateRemote: BeadsDoltRemote?
        if (draft.profile == .solo || draft.profile == .team),
           let remoteURL = draft.remoteURL.nilIfBlank {
            candidateRemote = BeadsDoltRemote(
                name: draft.remoteName,
                url: remoteURL,
                sqlURL: nil,
                status: nil
            )
        } else {
            candidateRemote = nil
        }
        return try await store.inspectBeadsSetup(
            projectURL: projectURL,
            candidateRemote: candidateRemote
        )
    }

    private func suggestedProfile(for assessment: BeadsSetupAssessment) -> BeadsSetupProfile {
        if assessment.environment?.role == .contributor { return .contributor }
        if assessment.remotes?.remotes.isEmpty == false { return .team }
        return assessment.isInitialized ? .advanced : .team
    }

    private func updateUseCaseAnswers(
        _ mutation: (inout BeadsSetupUseCaseAnswers) -> Void
    ) {
        var answers = useCaseAnswers
        mutation(&answers)
        useCaseAnswers = answers
        draft.useCaseAnswers = answers
        if let profile = answers.resolvedProfile {
            draft.applyProfileDefaults(profile, assessment: assessment)
        }
    }

    private func refreshPlan() {
        plan = assessment.map { BeadsSetupPlanner.plan(draft: draft, assessment: $0) }
    }
}

private struct BeadsSetupStepList: View {
    let currentStep: BeadsSetupWizardModel.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Beads Setup")
                .font(.headline)
                .padding(.bottom, 12)

            ForEach(BeadsSetupWizardModel.Step.allCases, id: \.self) { step in
                Label {
                    Text(step.title)
                } icon: {
                    Image(systemName: icon(for: step))
                        .foregroundStyle(step.rawValue <= currentStep.rawValue ? Color.accentColor : .secondary)
                }
                .font(.callout)
                .foregroundStyle(step == currentStep ? .primary : .secondary)
                .padding(.vertical, 5)
                .accessibilityAddTraits(step == currentStep ? .isSelected : [])
            }
            Spacer()
        }
        .padding(20)
    }

    private func icon(for step: BeadsSetupWizardModel.Step) -> String {
        if step.rawValue < currentStep.rawValue { return "checkmark.circle.fill" }
        if step == currentStep { return "circle.inset.filled" }
        return "circle"
    }
}

private struct BeadsSetupInspectStep: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        BeadsSetupStepContainer(
            title: "Inspecting this project",
            subtitle: "Beadazzle reads the effective bd context before proposing any changes."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if model.isInspecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.projectURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let failure = model.failure {
                    BeadsSetupFailureView(failure: failure)
                }
            }
        }
    }
}

private struct BeadsSetupConfigureStep: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        @Bindable var model = model

        BeadsSetupStepContainer(
            title: "Configure \(model.draft.profile.title)",
            subtitle: configurationSubtitle,
            scrolls: false
        ) {
            Form {
                if model.assessment?.isInitialized == false,
                   model.assessment?.bootstrap.recommendsBootstrap == false {
                    Section("New tracker") {
                        TextField("Issue prefix", text: $model.draft.prefix)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Use stealth mode", isOn: $model.draft.usesStealthMode)
                        Toggle("Update AGENTS.md", isOn: Binding(
                            get: { !model.draft.skipsAgents },
                            set: { model.draft.skipsAgents = !$0 }
                        ))
                    }
                }

                if model.draft.profile == .solo || model.draft.profile == .team {
                    BeadsSetupRemoteConfigurationSection(model: model)
                }

                BeadsSetupHooksConfigurationSection(model: model)

                BeadsSetupBackupConfigurationSection(model: model)

                if let plan = model.plan, !plan.findings.isEmpty {
                    Section("Findings") {
                        ForEach(plan.findings) { finding in
                            BeadsSetupFindingRow(finding: finding)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onChange(of: model.draft.usesStealthMode) { _, usesStealthMode in
                if usesStealthMode {
                    model.draft.installsHooks = false
                }
            }
        }
    }

    private var configurationSubtitle: String {
        model.draft.profile == .contributor
            ? "Contributor initialization follows bd's effective routing and upstream configuration."
            : "Existing remote histories and storage modes are never replaced automatically."
    }
}

private struct BeadsSetupReviewStep: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        BeadsSetupStepContainer(
            title: "Review changes",
            subtitle: "Commands run in order. Setup stops at the first failure and then refreshes any readable data."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let plan = model.plan {
                    if plan.steps.isEmpty {
                        Label("No bd commands are needed", systemImage: "checkmark.circle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.steps) { step in
                            BeadsSetupReviewRow(step: step)
                        }
                    }

                    BeadsSetupLocalIntentReviewRow(profile: plan.profile)

                    ForEach(plan.findings) { finding in
                        BeadsSetupFindingRow(finding: finding)
                    }
                }

                if let failure = model.failure {
                    BeadsSetupFailureView(failure: failure)
                }
            }
        }
    }
}

private struct BeadsSetupLocalIntentReviewRow: View {
    let profile: BeadsSetupProfile

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "macbook")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Remember \(profile.title)").font(.headline)
                Text("Save the intended use locally so future setup checks can report meaningful differences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(BeadsSetupChangeScope.beadazzleOnly.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BeadsSetupResultsStep: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        BeadsSetupStepContainer(
            title: "Setup complete",
            subtitle: "The project was exported and reloaded from its effective tracker directory."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Beads is configured for \(model.draft.profile.title).", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                Text("Beadazzle saved the intended setup for this checkout. If a future audit finds a meaningful difference, the workspace and Project Settings will offer this wizard again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let report = model.report {
                    if report.completedStepIDs.isEmpty {
                        Text("No bd commands were needed.").font(.callout)
                    } else {
                        Text("\(report.completedStepIDs.count) setup change\(report.completedStepIDs.count == 1 ? "" : "s") applied.")
                            .font(.callout)
                    }
                }
            }
        }
    }
}

private struct BeadsSetupWizardButtons: View {
    @Environment(BeadStore.self) private var store
    let model: BeadsSetupWizardModel
    let dismiss: DismissAction

    var body: some View {
        HStack {
            if model.step != .results {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isApplying)
            }
            Spacer()
            if model.step.rawValue > BeadsSetupWizardModel.Step.useCase.rawValue && model.step != .results {
                Button("Back") { model.goBack() }
                    .disabled(model.isApplying)
            }
            switch model.step {
            case .inspect:
                Button("Retry") {
                    Task { await model.inspect(using: store) }
                }
                .disabled(model.isInspecting)
            case .useCase:
                Button("Continue") { model.continueForward() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            case .configure:
                Button {
                    Task { await model.prepareReview(using: store) }
                } label: {
                    if model.isInspecting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking")
                        }
                    } else {
                        Text("Review")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue || model.isInspecting)
            case .review:
                Button {
                    Task { await model.apply(using: store) }
                } label: {
                    if model.isApplying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Applying")
                        }
                    } else {
                        Text("Apply Setup")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
            case .results:
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

struct BeadsSetupStepContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let scrolls: Bool
    let content: Content

    init(
        title: String,
        subtitle: String,
        scrolls: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if scrolls {
            ScrollView { layout }
        } else {
            layout
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BeadsSetupReviewRow: View {
    let step: BeadsSetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.forward.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title).font(.headline)
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                Text(step.scopes.map(\.title).joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(step.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BeadsSetupFindingRow: View {
    let finding: BeadsSetupFinding

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.headline)
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var iconName: String {
        switch finding.severity {
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .blocking: "exclamationmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch finding.severity {
        case .information: .accentColor
        case .warning: .orange
        case .blocking: .red
        }
    }
}

private struct BeadsSetupFailureView: View {
    let failure: BeadsSetupFailurePresentation

    private var details: BeadCommandFailureDetails {
        BeadCommandFailureDetails(command: failure.command, output: failure.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title).font(.headline)
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }

            if !details.isEmpty {
                BeadCommandFailureDetailsView(details: details)
                Button("Copy", systemImage: "doc.on.doc") {
                    details.copyToPasteboard()
                }
                .help("Copy the command and its output")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
