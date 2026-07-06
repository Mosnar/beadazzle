import AppKit
import SwiftUI

struct SettingsPaneContainer<Pane, SidebarLabel, Detail>: View
where Pane: Identifiable & Hashable, SidebarLabel: View, Detail: View {
    let panes: [Pane]
    @Binding var selection: Pane
    let title: (Pane) -> String
    let sidebarWidth: CGFloat
    let minDetailWidth: CGFloat
    let minHeight: CGFloat
    @ViewBuilder let sidebarLabel: (Pane) -> SidebarLabel
    @ViewBuilder let detail: (Pane) -> Detail

    @State private var backStack: [Pane] = []
    @State private var forwardStack: [Pane] = []

    init(
        panes: [Pane],
        selection: Binding<Pane>,
        title: @escaping (Pane) -> String,
        sidebarWidth: CGFloat = 196,
        minDetailWidth: CGFloat = 540,
        minHeight: CGFloat = 460,
        @ViewBuilder sidebarLabel: @escaping (Pane) -> SidebarLabel,
        @ViewBuilder detail: @escaping (Pane) -> Detail
    ) {
        self.panes = panes
        self._selection = selection
        self.title = title
        self.sidebarWidth = sidebarWidth
        self.minDetailWidth = minDetailWidth
        self.minHeight = minHeight
        self.sidebarLabel = sidebarLabel
        self.detail = detail
    }

    private var optionalSelection: Binding<Pane?> {
        Binding {
            selection
        } set: { newSelection in
            if let newSelection {
                select(newSelection)
            }
        }
    }

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                content(extendsIntoTitlebar: true, reservesDetailTitlebar: true)
                    .ignoresSafeArea(.container, edges: .top)
            } else {
                content(extendsIntoTitlebar: false, reservesDetailTitlebar: false)
            }
        }
        .settingsWindowChrome()
        .background {
            SettingsWindowButtonPositioner(
                leadingInset: SettingsPaneMetrics.windowButtonLeadingInset,
                topInset: SettingsPaneMetrics.windowButtonTopInset
            )
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: sidebarWidth + minDetailWidth, minHeight: minHeight)
    }

    private func select(_ pane: Pane) {
        guard pane != selection else { return }
        backStack.append(selection)
        forwardStack.removeAll()
        selection = pane
    }

    private func goBack() {
        guard let pane = backStack.popLast() else { return }
        forwardStack.append(selection)
        selection = pane
    }

    private func goForward() {
        guard let pane = forwardStack.popLast() else { return }
        backStack.append(selection)
        selection = pane
    }

    private func content(extendsIntoTitlebar: Bool, reservesDetailTitlebar: Bool) -> some View {
        HStack(spacing: 0) {
            sidebar(extendsIntoTitlebar: extendsIntoTitlebar)

            VStack(spacing: 0) {
                if reservesDetailTitlebar {
                    SettingsDetailTitlebar(
                        title: title(selection),
                        canGoBack: !backStack.isEmpty,
                        canGoForward: !forwardStack.isEmpty,
                        goBack: goBack,
                        goForward: goForward
                    )
                }

                detail(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func sidebar(extendsIntoTitlebar: Bool) -> some View {
        VStack(spacing: 0) {
            if extendsIntoTitlebar {
                Color.clear
                    .frame(height: SettingsPaneMetrics.sidebarTitlebarHeight)
            }

            List(panes, selection: optionalSelection) { pane in
                sidebarLabel(pane)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, SettingsPaneMetrics.sidebarListTopMargin, for: .scrollContent)
            .contentMargins(.horizontal, SettingsPaneMetrics.sidebarListHorizontalMargin, for: .scrollContent)
        }
        .frame(width: sidebarWidth - 12)
        .settingsSidebarSurface()
        .padding(6)
        .accessibilityLabel("Settings Panes")
    }
}

private struct SettingsDetailTitlebar: View {
    let title: String
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                SettingsTitlebarIconButton(
                    systemImage: "chevron.left",
                    title: "Back",
                    isEnabled: canGoBack,
                    action: goBack
                )

                SettingsTitlebarIconButton(
                    systemImage: "chevron.right",
                    title: "Forward",
                    isEnabled: canGoForward,
                    action: goForward
                )
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(height: SettingsPaneMetrics.titlebarHeight)
        .padding(.leading, SettingsPaneMetrics.detailTitlebarLeadingPadding)
        .padding(.trailing, 24)
    }
}

private struct SettingsTitlebarIconButton: View {
    let systemImage: String
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: 28, height: 28)
                .background(
                    isHovered && isEnabled ? Color.primary.opacity(0.08) : .clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
        .onHover { isHovered = $0 }
    }
}

private enum SettingsPaneMetrics {
    static let titlebarHeight: CGFloat = 48
    static let sidebarTitlebarHeight: CGFloat = 42
    static let sidebarListTopMargin: CGFloat = 0
    static let sidebarListHorizontalMargin: CGFloat = 6
    static let sidebarCornerRadius: CGFloat = 14
    static let detailTitlebarLeadingPadding: CGFloat = 14
    static let windowButtonLeadingInset: CGFloat = 20
    static let windowButtonTopInset: CGFloat = 18
}

private struct SettingsWindowButtonPositioner: NSViewRepresentable {
    let leadingInset: CGFloat
    let topInset: CGFloat

    func makeNSView(context: Context) -> WindowButtonPositioningView {
        let view = WindowButtonPositioningView()
        view.leadingInset = leadingInset
        view.topInset = topInset
        return view
    }

    func updateNSView(_ nsView: WindowButtonPositioningView, context: Context) {
        nsView.leadingInset = leadingInset
        nsView.topInset = topInset
        nsView.positionButtonsOnNextRunLoop()
    }

    final class WindowButtonPositioningView: NSView {
        var leadingInset: CGFloat = 20
        var topInset: CGFloat = 18

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            positionButtonsOnNextRunLoop()
        }

        override func layout() {
            super.layout()
            positionButtonsOnNextRunLoop()
        }

        func positionButtonsOnNextRunLoop() {
            DispatchQueue.main.async { [weak self] in
                self?.positionButtons()
            }
        }

        private func positionButtons() {
            guard let window,
                  let closeButton = window.standardWindowButton(.closeButton),
                  let minimizeButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton),
                  let buttonContainer = closeButton.superview
            else { return }

            let closeFrame = closeButton.frame
            let minimizeXOffset = minimizeButton.frame.minX - closeFrame.minX
            let zoomXOffset = zoomButton.frame.minX - closeFrame.minX
            let yOrigin = buttonContainer.bounds.height - topInset - closeFrame.height

            closeButton.setFrameOrigin(NSPoint(x: leadingInset, y: yOrigin))
            minimizeButton.setFrameOrigin(NSPoint(x: leadingInset + minimizeXOffset, y: yOrigin))
            zoomButton.setFrameOrigin(NSPoint(x: leadingInset + zoomXOffset, y: yOrigin))
        }
    }
}

private struct SettingsSidebarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
                    .glassEffect(.regular, in: .rect(cornerRadius: SettingsPaneMetrics.sidebarCornerRadius))
            }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SettingsPaneMetrics.sidebarCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsPaneMetrics.sidebarCornerRadius, style: .continuous)
                        .strokeBorder(.separator.opacity(0.22))
                }
        }
    }
}

private struct SettingsWindowChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

private struct SettingsGroupedForm: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.leading, 28, for: .scrollContent)
            .contentMargins(.trailing, 36, for: .scrollContent)
            .contentMargins(.bottom, 28, for: .scrollContent)
            .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension View {
    func settingsSidebarSurface() -> some View {
        modifier(SettingsSidebarSurface())
    }
    func settingsWindowChrome() -> some View {
        modifier(SettingsWindowChrome())
    }
}

extension View {
    func settingsGroupedForm(maxWidth: CGFloat = 760) -> some View {
        modifier(SettingsGroupedForm(maxWidth: maxWidth))
    }
}
