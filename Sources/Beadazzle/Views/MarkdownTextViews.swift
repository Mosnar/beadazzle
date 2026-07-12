import AppKit
import MarkdownEngine
import SwiftUI

struct MarkdownFieldEditor: View {
    @Environment(BeadStore.self) private var store: BeadStore
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
        }
        .onDisappear {
            dismissPreview()
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
