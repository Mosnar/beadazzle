import SwiftUI

struct IssueDetailPage: View {
    let issue: BeadIssue
    @Binding var draft: IssueDraft
    let isDirty: Bool
    let saveAction: () -> Void
    let revertAction: () -> Void
    let requestClose: (BeadIssue) -> Void

    var body: some View {
        IssueEditingPageShell {
            IssueBreadcrumbBar(
                issue: issue,
                isDirty: isDirty,
                canSave: !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                saveAction: saveAction,
                revertAction: revertAction,
                requestClose: requestClose
            )
        } compactAccessory: {
            IssueMetadataRibbon(draft: $draft)
        } content: { usesInspectorRail in
            IssueDetailContent(
                issue: issue,
                draft: $draft,
                usesInspectorRail: usesInspectorRail
            )
        }
    }
}

struct IssueCreationPage: View {
    @Binding var draft: IssueDraft
    let isCreating: Bool
    let createAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        IssueEditingPageShell {
            IssueCreationToolbar(
                draft: draft,
                canCreate: canCreate,
                isCreating: isCreating,
                createAction: createAction,
                cancelAction: cancelAction
            )
        } content: { usesInspectorRail in
            IssueCreationContent(
                draft: $draft,
                usesInspectorRail: usesInspectorRail
            )
        }
    }

    private var canCreate: Bool {
        !isCreating && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    static func horizontalPadding(usesInspectorRail: Bool) -> CGFloat {
        usesInspectorRail ? wideHorizontalPadding : compactHorizontalPadding
    }

    static func verticalPadding(usesInspectorRail: Bool) -> CGFloat {
        usesInspectorRail ? wideVerticalPadding : compactVerticalPadding
    }
}

private struct IssueEditingPageShell<Toolbar: View, CompactAccessory: View, Content: View>: View {
    private let toolbar: Toolbar
    private let compactAccessory: CompactAccessory
    private let showsCompactAccessory: Bool
    private let content: (Bool) -> Content

    init(
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder compactAccessory: () -> CompactAccessory,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.toolbar = toolbar()
        self.compactAccessory = compactAccessory()
        self.showsCompactAccessory = true
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            GeometryReader { proxy in
                let usesInspectorRail = IssueDetailLayout.usesInspectorRail(for: proxy.size.width)

                VStack(spacing: 0) {
                    if showsCompactAccessory && !usesInspectorRail {
                        compactAccessory
                        Divider()
                    }

                    ScrollView {
                        content(usesInspectorRail)
                            .padding(
                                .horizontal,
                                IssueDetailLayout.horizontalPadding(usesInspectorRail: usesInspectorRail)
                            )
                            .padding(
                                .vertical,
                                IssueDetailLayout.verticalPadding(usesInspectorRail: usesInspectorRail)
                            )
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

private extension IssueEditingPageShell where CompactAccessory == EmptyView {
    init(
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.toolbar = toolbar()
        self.compactAccessory = EmptyView()
        self.showsCompactAccessory = false
        self.content = content
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
                    IssueDetailBody(
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

                IssueDetailBody(
                    documentIDPrefix: issue.id,
                    issue: issue,
                    draft: $draft
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct IssueDetailBody: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var detail: BeadDetailStore { store.detail }
    let documentIDPrefix: String
    let issue: BeadIssue
    @Binding var draft: IssueDraft
    @State private var isRunningBlockedAction = false
    @State private var decisionGateForApproval: BeadGate?
    @State private var decisionGateForRejection: BeadGate?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let blockedActionPresentation {
                BlockedActionBanner(
                    presentation: blockedActionPresentation,
                    isBusy: isRunningBlockedAction,
                    perform: performBlockedAction
                )
                .id(blockedActionPresentation.id)
            }

            IssueBodySections(
                documentIDPrefix: documentIDPrefix,
                issue: issue,
                draft: $draft
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(item: $decisionGateForApproval) { gate in
            GateApproveSheet(gate: gate, affectedBeads: store.gateDecisionAffectedBeads(for: gate.id)) { reason in
                await performGateDecision { await store.approveGate(id: gate.id, reason: reason) }
            }
        }
        .sheet(item: $decisionGateForRejection) { gate in
            GateRejectSheet(
                gate: gate,
                affectedBeads: store.gateDecisionAffectedBeads(for: gate.id),
                statusOptions: store.gateRejectionStatusOptions,
                defaultStatus: store.defaultGateRejectionStatus,
                isDeferredStatus: { store.isDeferredStatus($0) }
            ) { reason, status, deferUntil in
                await performGateDecision {
                    await store.rejectGate(
                        id: gate.id,
                        reason: reason,
                        targetStatus: status,
                        deferUntil: deferUntil
                    )
                }
            }
        }
    }

    private var blockedActionPresentation: BlockedActionPresentation? {
        BlockedActionPresentation.make(
            issueID: issue.id,
            reason: store.blockedReasonPresentation(for: issue.id, now: detail.gateClock),
            canCreateGate: store.canCreateGate(blocking: issue),
            readyDecisionGate: readyDecisionGate
        )
    }

    /// The open human decision gate blocking this bead, if any — it can be approved or
    /// rejected right now, so the banner surfaces those actions inline.
    private var readyDecisionGate: BeadGate? {
        store.gatesBlocking(issueID: issue.id).first { gate in
            gate.awaitType == .human && gate.actionState(now: detail.gateClock).isReady
        }
    }

    private func performBlockedAction(_ action: BlockedActionPresentation.Action) {
        guard !isRunningBlockedAction else { return }
        switch action {
        case .approve:
            decisionGateForApproval = readyDecisionGate
        case .reject:
            decisionGateForRejection = readyDecisionGate
        case .createTimer:
            runBlockedAction {
                await store.createGate(blocks: issue.id, type: .timer, reason: nil, timeout: "8h", awaitID: nil)
            }
        case .createDecision:
            runBlockedAction {
                await store.createGate(blocks: issue.id, type: .human, reason: nil, timeout: nil, awaitID: nil)
            }
        case .reopen:
            runBlockedAction {
                await store.reopenBlockedIssue(issueID: issue.id)
            }
        }
    }

    private func runBlockedAction(_ action: @escaping () async -> Bool) {
        guard !isRunningBlockedAction else { return }
        isRunningBlockedAction = true
        Task { @MainActor in
            defer { isRunningBlockedAction = false }
            _ = await action()
        }
    }

    /// Sheet completion handler: the sheets dismiss themselves only when this returns true.
    private func performGateDecision(_ action: () async -> Bool) async -> Bool {
        guard !isRunningBlockedAction else { return false }
        isRunningBlockedAction = true
        defer { isRunningBlockedAction = false }
        return await action()
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
                SubIssuesView(issue: issue)
                CommentsView(issue: issue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func documentID(for section: IssueTextSection) -> String {
        "\(documentIDPrefix)-\(section.storageKey)"
    }
}
