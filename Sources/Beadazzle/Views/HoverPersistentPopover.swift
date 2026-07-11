import SwiftUI

enum HoverPopoverTiming {
    static let openDelay: Duration = .milliseconds(320)
    static let closeDelay: Duration = .milliseconds(280)
}

struct HoverPersistentPopoverPresentationState: Equatable {
    var isTriggerHovered = false
    var isPreviewHovered = false
    var isPresented = false
    var isPinned = false

    var shouldOpenAfterDelay: Bool {
        isTriggerHovered && !isPresented
    }

    var shouldCloseAfterDelay: Bool {
        !isPinned && !isTriggerHovered && !isPreviewHovered
    }

    mutating func togglePin() {
        isPinned.toggle()
        isPresented = isPinned || isTriggerHovered || isPreviewHovered
    }

    mutating func dismiss() {
        isTriggerHovered = false
        isPreviewHovered = false
        isPinned = false
        isPresented = false
    }
}

struct HoverPersistentPopover<Label: View, Preview: View>: View {
    private enum ClickBehavior {
        case performAction
        case pinPreview
    }

    private let arrowEdge: Edge
    private let openDelay: Duration
    private let closeDelay: Duration
    private let fillsAvailableWidth: Bool
    private let clickBehavior: ClickBehavior
    private let action: () -> Void
    private let label: (Bool) -> Label
    private let preview: () -> Preview

    @State private var presentation = HoverPersistentPopoverPresentationState()
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?

    init(
        arrowEdge: Edge = .leading,
        openDelay: Duration = HoverPopoverTiming.openDelay,
        closeDelay: Duration = HoverPopoverTiming.closeDelay,
        fillsAvailableWidth: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping (Bool) -> Label,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        self.arrowEdge = arrowEdge
        self.openDelay = openDelay
        self.closeDelay = closeDelay
        self.fillsAvailableWidth = fillsAvailableWidth
        self.clickBehavior = .performAction
        self.action = action
        self.label = label
        self.preview = preview
    }

    init(
        arrowEdge: Edge = .leading,
        openDelay: Duration = HoverPopoverTiming.openDelay,
        closeDelay: Duration = HoverPopoverTiming.closeDelay,
        fillsAvailableWidth: Bool = true,
        @ViewBuilder label: @escaping (Bool) -> Label,
        @ViewBuilder interactivePreview: @escaping () -> Preview
    ) {
        self.arrowEdge = arrowEdge
        self.openDelay = openDelay
        self.closeDelay = closeDelay
        self.fillsAvailableWidth = fillsAvailableWidth
        clickBehavior = .pinPreview
        action = {}
        self.label = label
        self.preview = interactivePreview
    }

    var body: some View {
        Button {
            switch clickBehavior {
            case .performAction:
                hideImmediately()
                action()
            case .pinPreview:
                openTask?.cancel()
                closeTask?.cancel()
                setPresentation { $0.togglePin() }
            }
        } label: {
            label(presentation.isTriggerHovered)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
        .onHover { hovering in
            updateLinkHover(hovering)
        }
        .onDisappear {
            hideImmediately()
        }
        .popover(isPresented: $presentation.isPresented, arrowEdge: arrowEdge) {
            preview()
                .contentShape(Rectangle())
                .onHover { hovering in
                    updatePreviewHover(hovering)
                }
        }
        .onChange(of: presentation.isPresented) {
            if !presentation.isPresented {
                presentation.isPinned = false
            }
        }
    }

    private func updateLinkHover(_ hovering: Bool) {
        presentation.isTriggerHovered = hovering

        if hovering {
            scheduleOpen()
        } else {
            scheduleClose()
        }
    }

    private func updatePreviewHover(_ hovering: Bool) {
        presentation.isPreviewHovered = hovering

        if hovering {
            closeTask?.cancel()
        } else {
            scheduleClose()
        }
    }

    private func scheduleOpen() {
        closeTask?.cancel()
        openTask?.cancel()
        guard !presentation.isPresented else { return }

        openTask = Task { @MainActor in
            try? await Task.sleep(for: openDelay)
            guard !Task.isCancelled, presentation.shouldOpenAfterDelay else { return }
            setPresented(true)
        }
    }

    private func scheduleClose() {
        openTask?.cancel()
        closeTask?.cancel()

        closeTask = Task { @MainActor in
            try? await Task.sleep(for: closeDelay)
            guard !Task.isCancelled, presentation.shouldCloseAfterDelay else { return }
            setPresented(false)
        }
    }

    private func hideImmediately() {
        openTask?.cancel()
        closeTask?.cancel()
        setPresentation { $0.dismiss() }
    }

    private func setPresented(_ presented: Bool) {
        setPresentation { $0.isPresented = presented }
    }

    private func setPresentation(_ update: (inout HoverPersistentPopoverPresentationState) -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            update(&presentation)
        }
    }
}
