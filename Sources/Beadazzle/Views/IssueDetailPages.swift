import SwiftUI

struct IssueDetailPage: View {
    let issue: BeadIssue
    @Binding var draft: IssueDraft
    let isDirty: Bool
    let saveAction: () -> Void
    let revertAction: () -> Void
    let requestClose: (BeadIssue) -> Void

    var body: some View {
        VStack(spacing: 0) {
            IssueBreadcrumbBar(
                issue: issue,
                isDirty: isDirty,
                canSave: !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                saveAction: saveAction,
                revertAction: revertAction,
                requestClose: requestClose
            )

            Divider()

            GeometryReader { proxy in
                let usesInspectorRail = IssueDetailLayout.usesInspectorRail(for: proxy.size.width)

                VStack(spacing: 0) {
                    if !usesInspectorRail {
                        IssueMetadataRibbon(draft: $draft)
                        Divider()
                    }

                    ScrollView {
                        IssueDetailContent(
                            issue: issue,
                            draft: $draft,
                            usesInspectorRail: usesInspectorRail
                        )
                        .padding(.horizontal, horizontalPadding(usesInspectorRail: usesInspectorRail))
                        .padding(.vertical, verticalPadding(usesInspectorRail: usesInspectorRail))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func horizontalPadding(usesInspectorRail: Bool) -> CGFloat {
        usesInspectorRail ? IssueDetailLayout.wideHorizontalPadding : IssueDetailLayout.compactHorizontalPadding
    }

    private func verticalPadding(usesInspectorRail: Bool) -> CGFloat {
        usesInspectorRail ? IssueDetailLayout.wideVerticalPadding : IssueDetailLayout.compactVerticalPadding
    }
}

struct IssueCreationPage: View {
    @Binding var draft: IssueDraft
    let isCreating: Bool
    let createAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            IssueCreationToolbar(
                draft: draft,
                canCreate: canCreate,
                isCreating: isCreating,
                createAction: createAction,
                cancelAction: cancelAction
            )

            Divider()

            GeometryReader { proxy in
                let usesInspectorRail = IssueDetailLayout.usesInspectorRail(for: proxy.size.width)

                ScrollView {
                    IssueCreationContent(
                        draft: $draft,
                        usesInspectorRail: usesInspectorRail
                    )
                    .padding(.horizontal, horizontalPadding(usesInspectorRail: usesInspectorRail))
                    .padding(.vertical, verticalPadding(usesInspectorRail: usesInspectorRail))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var canCreate: Bool {
        !isCreating && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func horizontalPadding(usesInspectorRail: Bool) -> CGFloat {
        usesInspectorRail ? IssueDetailLayout.wideHorizontalPadding : IssueDetailLayout.compactHorizontalPadding
    }

    private func verticalPadding(usesInspectorRail: Bool) -> CGFloat {
        usesInspectorRail ? IssueDetailLayout.wideVerticalPadding : IssueDetailLayout.compactVerticalPadding
    }
}

enum IssueDetailLayout {
    static let mainColumnMinWidth: CGFloat = 380
    static let mainColumnIdealWidth: CGFloat = 720
    static let mainColumnMaxWidth: CGFloat = 820
    static let textColumnMaxWidth: CGFloat = 700
    static let inspectorWidth: CGFloat = 280
    static let inspectorGap: CGFloat = 32
    static let wideHorizontalPadding: CGFloat = 36
    static let compactHorizontalPadding: CGFloat = 28
    static let wideVerticalPadding: CGFloat = 40
    static let compactVerticalPadding: CGFloat = 28
    static let contentMaxWidth = mainColumnMaxWidth + inspectorGap + inspectorWidth
    static let railBreakpoint = mainColumnMinWidth + inspectorGap + inspectorWidth + (wideHorizontalPadding * 2)

    static func usesInspectorRail(for width: CGFloat) -> Bool {
        width >= railBreakpoint
    }
}

struct IssueDetailContent: View {
    let issue: BeadIssue
    @Binding var draft: IssueDraft
    let usesInspectorRail: Bool

    var body: some View {
        if usesInspectorRail {
            HStack(alignment: .top, spacing: 0) {
                IssueMainColumn(draft: $draft) {
                    IssueBodySections(
                        documentIDPrefix: issue.id,
                        issue: issue,
                        draft: $draft
                    )
                }
                .frame(
                    minWidth: IssueDetailLayout.mainColumnMinWidth,
                    idealWidth: IssueDetailLayout.mainColumnIdealWidth,
                    maxWidth: IssueDetailLayout.mainColumnMaxWidth,
                    alignment: .topLeading
                )

                Spacer(minLength: IssueDetailLayout.inspectorGap)

                IssueInspector(issue: issue, draft: $draft)
                    .frame(width: IssueDetailLayout.inspectorWidth, alignment: .topLeading)
            }
            .frame(maxWidth: IssueDetailLayout.contentMaxWidth, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 26) {
                IssueTitleBlock(draft: $draft)

                IssueBodySections(
                    documentIDPrefix: issue.id,
                    issue: issue,
                    draft: $draft
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct IssueCreationContent: View {
    @Binding var draft: IssueDraft
    let usesInspectorRail: Bool

    var body: some View {
        if usesInspectorRail {
            HStack(alignment: .top, spacing: 0) {
                IssueMainColumn(draft: $draft, focusesTitle: true) {
                    IssueBodySections(
                        documentIDPrefix: "new-bead",
                        issue: nil,
                        draft: $draft
                    )
                }
                .frame(
                    minWidth: IssueDetailLayout.mainColumnMinWidth,
                    idealWidth: IssueDetailLayout.mainColumnIdealWidth,
                    maxWidth: IssueDetailLayout.mainColumnMaxWidth,
                    alignment: .topLeading
                )

                Spacer(minLength: IssueDetailLayout.inspectorGap)

                IssueCreationInspector(draft: $draft)
                    .frame(width: IssueDetailLayout.inspectorWidth, alignment: .topLeading)
            }
            .frame(maxWidth: IssueDetailLayout.contentMaxWidth, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                IssueTitleBlock(draft: $draft, focusesTitle: true)

                IssueCreationInspector(draft: $draft)

                IssueBodySections(
                    documentIDPrefix: "new-bead",
                    issue: nil,
                    draft: $draft
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct IssueMainColumn<Content: View>: View {
    @Binding var draft: IssueDraft
    let focusesTitle: Bool
    let content: Content

    init(draft: Binding<IssueDraft>, focusesTitle: Bool = false, @ViewBuilder content: () -> Content) {
        self._draft = draft
        self.focusesTitle = focusesTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            IssueTitleBlock(draft: $draft, focusesTitle: focusesTitle)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct IssueBodySections: View {
    let documentIDPrefix: String
    let issue: BeadIssue?
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            EditableTextSection(
                section: .description,
                text: $draft.description,
                documentID: documentID(for: .description)
            )

            EditableTextSection(
                section: .acceptanceCriteria,
                text: $draft.acceptanceCriteria,
                documentID: documentID(for: .acceptanceCriteria)
            )

            EditableTextSection(
                section: .design,
                text: $draft.design,
                documentID: documentID(for: .design)
            )

            EditableTextSection(
                section: .notes,
                text: $draft.notes,
                documentID: documentID(for: .notes)
            )

            if let issue {
                DependenciesView(issue: issue)
                CommentsView(issue: issue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func documentID(for section: IssueTextSection) -> String {
        "\(documentIDPrefix)-\(section.storageKey)"
    }
}
