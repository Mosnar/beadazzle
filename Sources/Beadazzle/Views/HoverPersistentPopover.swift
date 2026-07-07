import SwiftUI

struct HoverPersistentPopover<Label: View, Preview: View>: View {
    private let arrowEdge: Edge
    private let openDelay: Duration
    private let closeDelay: Duration
    private let action: () -> Void
    private let label: (Bool) -> Label
    private let preview: () -> Preview

    @State private var isLinkHovered = false
    @State private var isPreviewHovered = false
    @State private var isPresented = false
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?

    init(
        arrowEdge: Edge = .leading,
        openDelay: Duration = .milliseconds(320),
        closeDelay: Duration = .milliseconds(280),
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping (Bool) -> Label,
        @ViewBuilder preview: @escaping () -> Preview
    ) {
        self.arrowEdge = arrowEdge
        self.openDelay = openDelay
        self.closeDelay = closeDelay
        self.action = action
        self.label = label
        self.preview = preview
    }

    var body: some View {
        Button {
            hideImmediately()
            action()
        } label: {
            label(isLinkHovered)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            updateLinkHover(hovering)
        }
        .onDisappear {
            hideImmediately()
        }
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            preview()
                .contentShape(Rectangle())
                .onHover { hovering in
                    updatePreviewHover(hovering)
                }
        }
    }

    private func updateLinkHover(_ hovering: Bool) {
        isLinkHovered = hovering

        if hovering {
            scheduleOpen()
        } else {
            scheduleClose()
        }
    }

    private func updatePreviewHover(_ hovering: Bool) {
        isPreviewHovered = hovering

        if hovering {
            closeTask?.cancel()
        } else {
            scheduleClose()
        }
    }

    private func scheduleOpen() {
        closeTask?.cancel()
        openTask?.cancel()
        guard !isPresented else { return }

        openTask = Task { @MainActor in
            try? await Task.sleep(for: openDelay)
            guard !Task.isCancelled, isLinkHovered else { return }
            setPresented(true)
        }
    }

    private func scheduleClose() {
        openTask?.cancel()
        closeTask?.cancel()

        closeTask = Task { @MainActor in
            try? await Task.sleep(for: closeDelay)
            guard !Task.isCancelled, !isLinkHovered, !isPreviewHovered else { return }
            setPresented(false)
        }
    }

    private func hideImmediately() {
        openTask?.cancel()
        closeTask?.cancel()
        isLinkHovered = false
        isPreviewHovered = false
        setPresented(false)
    }

    private func setPresented(_ presented: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = presented
        }
    }
}
