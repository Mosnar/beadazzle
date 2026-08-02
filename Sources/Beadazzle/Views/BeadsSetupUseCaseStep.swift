import SwiftUI

struct BeadsSetupUseCaseStep: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        BeadsSetupStepContainer(
            title: "Tell us how you work",
            subtitle: "A few plain-language questions will choose safe defaults. You can still review every command before it runs."
        ) {
            if model.useCaseAnswers.usesAdvancedSetup {
                BeadsSetupAdvancedSelection(model: model)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    BeadsSetupQuestionBlock(
                        title: "Are you working on your own project or contributing to someone else’s?"
                    ) {
                        BeadsSetupAnswerRow {
                            BeadsSetupAnswerButton(
                                title: "My own project",
                                detail: "I maintain the project and can decide how its task tracker is configured.",
                                isSelected: model.useCaseAnswers.projectRelationship == .ownProject
                            ) {
                                model.selectProjectRelationship(.ownProject)
                            }
                            BeadsSetupAnswerButton(
                                title: "Someone else’s project",
                                detail: "I’m contributing to a project maintained by someone else.",
                                isSelected: model.useCaseAnswers.projectRelationship == .contributing
                            ) {
                                model.selectProjectRelationship(.contributing)
                            }
                        }
                    }

                    if model.useCaseAnswers.projectRelationship == .contributing {
                        BeadsSetupQuestionBlock(
                            title: "Does this project have a shared task database you should use?",
                            detail: "Choose the shared option if the project’s maintainers expect you to pull and push its existing task data."
                        ) {
                            BeadsSetupAnswerRow {
                                BeadsSetupAnswerButton(
                                    title: "Yes, use the project’s tracker",
                                    detail: "Join the existing shared task database.",
                                    isSelected: model.useCaseAnswers.usesProjectSharedTracker == true
                                ) {
                                    model.selectProjectTrackerSharing(true)
                                }
                                BeadsSetupAnswerButton(
                                    title: "No, keep my planning separate",
                                    detail: "Use contributor routing without changing the maintainer tracker.",
                                    isSelected: model.useCaseAnswers.usesProjectSharedTracker == false
                                ) {
                                    model.selectProjectTrackerSharing(false)
                                }
                            }
                        }
                    }

                    if model.useCaseAnswers.projectRelationship == .ownProject {
                        BeadsSetupQuestionBlock(
                            title: "Are you working on this project alone or with a team?"
                        ) {
                            BeadsSetupAnswerRow {
                                BeadsSetupAnswerButton(
                                    title: "On my own",
                                    detail: "I’m the only person maintaining this project’s task data.",
                                    isSelected: model.useCaseAnswers.collaborationStyle == .alone
                                ) {
                                    model.selectCollaborationStyle(.alone)
                                }
                                BeadsSetupAnswerButton(
                                    title: "With a team",
                                    detail: "Other people work on the project from their own checkouts.",
                                    isSelected: model.useCaseAnswers.collaborationStyle == .team
                                ) {
                                    model.selectCollaborationStyle(.team)
                                }
                            }
                        }
                    }

                    if model.useCaseAnswers.collaborationStyle == .team {
                        BeadsSetupQuestionBlock(
                            title: "Do you want everyone to share the same task database?",
                            detail: "This lets the team pull and push one shared issue history while keeping it separate from source-code branches."
                        ) {
                            BeadsSetupAnswerRow {
                                BeadsSetupAnswerButton(
                                    title: "Yes, share it",
                                    detail: "Everyone works from the same task database.",
                                    isSelected: model.useCaseAnswers.sharesTrackerWithTeam == true
                                ) {
                                    model.selectTeamSharing(true)
                                }
                                BeadsSetupAnswerButton(
                                    title: "No, keep mine separate",
                                    detail: "My task database is not the team’s shared source of truth.",
                                    isSelected: model.useCaseAnswers.sharesTrackerWithTeam == false
                                ) {
                                    model.selectTeamSharing(false)
                                }
                            }
                        }
                    }

                    if asksAboutPersonalSync {
                        BeadsSetupQuestionBlock(
                            title: "Do you want your task data to sync through this project’s Git remote?",
                            detail: "The task database travels through the same remote service, but remains separate from your source-code branches."
                        ) {
                            BeadsSetupAnswerRow {
                                BeadsSetupAnswerButton(
                                    title: "Yes, keep it synced",
                                    detail: "Make it available from my other checkouts or computers.",
                                    isSelected: model.useCaseAnswers.syncsThroughGit == true
                                ) {
                                    model.selectGitSync(true)
                                }
                                BeadsSetupAnswerButton(
                                    title: "No, keep it on this Mac",
                                    detail: "Do not upload this task database to a remote.",
                                    isSelected: model.useCaseAnswers.syncsThroughGit == false
                                ) {
                                    model.selectGitSync(false)
                                }
                            }
                        }
                    }

                    if let profile = model.useCaseAnswers.resolvedProfile {
                        BeadsSetupRecommendation(profile: profile)
                    }

                    Divider()
                    Button("Review an existing or custom setup instead…") {
                        model.selectAdvancedSetup()
                    }
                    .buttonStyle(.link)
                    .accessibilityHint("Skips the guided questions and preserves existing choices by default.")
                }
            }
        }
    }

    private var asksAboutPersonalSync: Bool {
        model.useCaseAnswers.collaborationStyle == .alone
    }
}

private struct BeadsSetupQuestionBlock<Answers: View>: View {
    let title: String
    let detail: String?
    let answers: Answers

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder answers: () -> Answers
    ) {
        self.title = title
        self.detail = detail
        self.answers = answers()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            answers
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct BeadsSetupAnswerRow<Answers: View>: View {
    let answers: Answers

    init(@ViewBuilder answers: () -> Answers) {
        self.answers = answers()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) { answers }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BeadsSetupAnswerButton: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BeadsSetupRecommendation: View {
    let profile: BeadsSetupProfile

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: profile.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recommended setup: \(profile.title)")
                    .font(.headline)
                Text(profile.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct BeadsSetupAdvancedSelection: View {
    let model: BeadsSetupWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BeadsSetupRecommendation(profile: .advanced)
            Text("Beadazzle will inspect the current configuration and preserve existing choices unless you explicitly select a safe change.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Answer the guided questions instead") {
                model.startGuidedSetup()
            }
        }
    }
}
