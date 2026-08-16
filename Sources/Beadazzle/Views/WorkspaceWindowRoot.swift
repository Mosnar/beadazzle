import AppKit
import SwiftUI

/// Root of one workspace window. Resolves the window's own `BeadStore` from the registry
/// and publishes its `NSWindow` back, so the registry can tell windows apart — bring the
/// window already showing a project forward, and know which store auxiliary scenes read.
struct WorkspaceWindowRoot: View {
    let registry: BeadWorkspaceWindowRegistry
    @Binding var request: BeadWorkspaceWindowRequest
    @Environment(\.openWindow) private var openWindow
    /// This window's registry identity, deliberately independent of the presented value.
    ///
    /// SwiftUI can hand a live window a different `BeadWorkspaceWindowRequest` after it has
    /// appeared — scene restoration swaps its own stored value in a beat after launch —
    /// and `onAppear` does not run again for the replacement. Keying the registry on
    /// `request.id` therefore rebound the window to a fresh, empty store and stranded the
    /// loaded one: its project stayed reserved and its file monitors kept running, while the
    /// switcher advertised that project as open in another window. Activating it did
    /// nothing, because the stranded entry still pointed at this very window. `@State` is
    /// created once per window and survives every value swap, so the window keeps its store.
    @State private var windowID = UUID()

    var body: some View {
        let store = registry.store(for: windowID)

        ContentView()
            .beadStoreEnvironment(store)
            .environment(registry)
            .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
            .navigationTitle(store.projectName)
            .background {
                WorkspaceWindowAccessor(isDocumentEdited: store.hasRecoverableWorkspaceDrafts) { window in
                    registry.registerWindow(window, for: windowID)
                }
                .frame(width: 0, height: 0)
            }
            .onAppear {
                registry.openNewWindow = { openWindow(value: $0) }
                registry.prepareWindow(windowID, request: request)
            }
            .onChange(of: request.id) {
                // A value the window never appeared with: restoration replacing its own
                // stored value, or a swap SwiftUI made for its own reasons. Honor a project
                // the replacement asks for only while this window has none — `prepareWindow`
                // no-ops otherwise, so a window already showing work is never yanked.
                registry.prepareWindow(windowID, request: request)
                recordProjectPath(store.projectURL)
            }
            .onChange(of: store.projectURL) { _, projectURL in
                recordProjectPath(projectURL)
            }
            .onDisappear {
                registry.releaseWindow(windowID)
            }
    }

    /// Keeps the presented value pointed at the project the window actually shows. Window
    /// restoration encodes that value, so a window that switched projects — or was handed a
    /// replacement value — would otherwise restore the wrong one.
    private func recordProjectPath(_ projectURL: URL?) {
        let path = projectURL?.standardizedFileURL.path
        guard request.projectPath != path else { return }
        request.projectPath = path
    }
}

/// Reports the hosting `NSWindow` once the view is in the window hierarchy. SwiftUI has no
/// first-party way to identify which window a scene ended up in, and window identity is
/// what "focus the window already showing this project" needs.
private struct WorkspaceWindowAccessor: NSViewRepresentable {
    let isDocumentEdited: Bool
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(isDocumentEdited: isDocumentEdited, onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowReportingView else { return }
        view.isDocumentEdited = isDocumentEdited
        view.onResolve = onResolve
        view.reportWindowIfNeeded()
    }

    private final class WindowReportingView: NSView {
        var isDocumentEdited: Bool
        var onResolve: (NSWindow) -> Void
        private weak var reportedWindow: NSWindow?

        init(isDocumentEdited: Bool, onResolve: @escaping (NSWindow) -> Void) {
            self.isDocumentEdited = isDocumentEdited
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowIfNeeded()
        }

        func reportWindowIfNeeded() {
            guard let window else { return }
            window.isDocumentEdited = isDocumentEdited
            guard window !== reportedWindow else { return }
            reportedWindow = window
            onResolve(window)
        }
    }
}
