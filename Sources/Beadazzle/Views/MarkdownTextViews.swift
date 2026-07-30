import AppKit
import MarkdownEngine
import SwiftUI

/// An invisible view parked on the focused find match so the detail page's
/// `ScrollViewReader` can reveal it. The engine can't scroll there itself: each
/// field sits in its own content-sized scroll view with no slack, and the
/// scrolling that matters happens in the outer detail `ScrollView`.
///
/// Deliberately its own view. Reading the find session inside
/// `MarkdownFieldEditor.body` would invalidate that body on every find
/// keystroke, and the engine's `updateNSView` reassigns
/// `coordinator.configuration`, whose `didSet` re-subscribes its notification
/// observers and rebuilds its extension registry — per keystroke, per field.
///
/// Positioned by a leading spacer rather than `.offset` because `scrollTo`
/// resolves the target's *layout* position, which an offset leaves untouched.
///
/// The spacer and the marker are separate children so that `.id` identifies
/// only the match-sized marker. Applying it to a padded container instead makes
/// the identified frame span from the field's top all the way to the match, and
/// `anchor: .center` then centers the midpoint of *that* — leaving a match deep
/// in a long field roughly half a field short of the viewport.
private struct FindScrollAnchor: View {
    @Environment(BeadFindSession.self) private var findSession: BeadFindSession?
    let documentID: String

    var body: some View {
        if let rect = findSession?.scrollAnchorRect(forDocumentID: documentID) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: 1, height: max(rect.minY, 0))

                Color.clear
                    .frame(width: 1, height: max(rect.height, 1))
                    .id(BeadFindScrollAnchor.id)

                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }
}

struct MarkdownFieldEditor: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(BeadFindSession.self) private var findSession: BeadFindSession?
    private var project: BeadProjectStore { store.project }
    private var workspace: BeadWorkspaceStore { store.workspace }
    @Binding var text: String
    let placeholder: String
    let documentID: String
    let minimumLineCount: Int
    @State private var hoveredLink: LinkHoverState?
    @State private var previewIssueID: String?
    @State private var isPreviewHovered = false
    @State private var isPreviewPresented = false
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontSize: Self.bodyFontSize,
            documentId: documentID,
            onLinkClick: openLink,
            onLinkHoverChange: updateLinkHover,
            placeholder: placeholderText
        )
        .frame(
            maxWidth: IssueDetailLayout.textColumnMaxWidth,
            minHeight: minimumHeight,
            alignment: .topLeading
        )
        .fixedSize(horizontal: false, vertical: true)
        // Find match rects arrive from the engine in the same top-leading
        // wrapper coordinates as the link-hover anchor below, so the anchor is
        // positioned against this frame — before the width-expanding one.
        .overlay(alignment: .topLeading) {
            FindScrollAnchor(documentID: documentID)
        }
        // The anchor rect arrives from the engine in the wrapper's top-leading
        // viewport coordinates, which is exactly the space `.rect(.rect(_:))`
        // resolves against here — attach before the width-expanding frame below.
        .popover(
            isPresented: $isPreviewPresented,
            attachmentAnchor: .rect(.rect(hoveredLink?.anchorRect ?? .zero)),
            arrowEdge: .bottom
        ) {
            linkPreview
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: documentID) {
            dismissPreview()
        }
        .onChange(of: project.projectURL) {
            dismissPreview()
        }
        .onChange(of: workspace.selectedIDs) {
            dismissPreview()
        }
        .onChange(of: project.issueReferenceLookup.revision) {
            dismissPreview()
            // A lookup revision restyles the field even though its text is
            // unchanged, which drops the highlights. Without this the bar would
            // keep reporting a count with nothing highlighted.
            findSession?.refreshMatches()
        }
        .onDisappear {
            dismissPreview()
        }
        // Editing a field makes the engine restyle it, which rebuilds its text
        // attributes and wipes the find highlights — so re-run the query.
        // Reading the session inside a closure rather than in `body` keeps this
        // from re-invalidating the wrapper on every find keystroke.
        .onChange(of: text) {
            findSession?.refreshMatches()
        }
    }

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.heightBehavior = .fitsContent
        config.scrollers = .hidden
        config.textInsets = .init(horizontal: 0, vertical: 0)
        config.paragraph = .init(spacingFactor: 0.18, lineHeightExtraSpacing: 2)
        config.spellChecking = .init(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false
        )
        config.services.automaticLinks = project.issueReferenceLookup
        // This window's find channel, so another window's search can't reach
        // these fields.
        if let bus = findSession?.bus {
            config.services.bus = bus.editorBus
        }
        // The engine defaults both find colors to systemYellow. Match the macOS
        // find convention instead: every match tinted, the focused one stronger.
        config.theme.findMatchHighlight = .systemYellow
        config.theme.findCurrentMatchHighlight = .systemOrange
        return config
    }

    @ViewBuilder
    private var linkPreview: some View {
        if let previewIssueID,
           let issue = store.issue(with: previewIssueID) {
            BeadDetailPreview(issue: issue)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isPreviewHovered = hovering
                    if hovering {
                        closeTask?.cancel()
                    } else {
                        scheduleClose()
                    }
                }
        }
    }

    private func openLink(_ target: String) {
        guard let url = URL(string: target),
              let issueID = BeadIssueURL.issueID(from: url),
              store.issue(with: issueID) != nil else {
            return
        }
        dismissPreview()
        store.openIssueFromDetail(issueID: issueID)
    }

    private func updateLinkHover(_ state: LinkHoverState?) {
        guard let state,
              let url = URL(string: state.target),
              let issueID = BeadIssueURL.issueID(from: url),
              store.issue(with: issueID) != nil else {
            scheduleClose()
            return
        }

        closeTask?.cancel()
        let targetChanged = previewIssueID != issueID
        hoveredLink = state
        previewIssueID = issueID
        if targetChanged {
            isPreviewPresented = false
        }
        scheduleOpen()
    }

    private func scheduleOpen() {
        openTask?.cancel()
        guard !isPreviewPresented else { return }
        openTask = Task { @MainActor in
            try? await Task.sleep(for: HoverPopoverTiming.openDelay)
            guard !Task.isCancelled, hoveredLink != nil, previewIssueID != nil else { return }
            isPreviewPresented = true
        }
    }

    private func scheduleClose() {
        openTask?.cancel()
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: HoverPopoverTiming.closeDelay)
            guard !Task.isCancelled, !isPreviewHovered else { return }
            isPreviewPresented = false
            hoveredLink = nil
            previewIssueID = nil
        }
    }

    private func dismissPreview() {
        openTask?.cancel()
        closeTask?.cancel()
        isPreviewHovered = false
        isPreviewPresented = false
        hoveredLink = nil
        previewIssueID = nil
    }

    private var placeholderText: NSAttributedString {
        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.bodyFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
    }

    private var minimumHeight: CGFloat {
        CGFloat(minimumLineCount) * 22
    }

    private static var bodyFontSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize
    }
}
