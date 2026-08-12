import AppKit
import SwiftUI

/// Root of one workspace window. Resolves the window's own `BeadStore` from the registry
/// and publishes its `NSWindow` back, so the registry can tell windows apart — bring the
/// window already showing a project forward, and know which store auxiliary scenes read.
struct WorkspaceWindowRoot: View {
    let registry: BeadWorkspaceWindowRegistry
    @Binding var request: BeadWorkspaceWindowRequest
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let store = registry.store(for: request)

        ContentView()
            .beadStoreEnvironment(store)
            .environment(registry)
            .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
            .navigationTitle(store.projectName)
            .background {
                WorkspaceWindowAccessor(isDocumentEdited: store.hasRecoverableWorkspaceDrafts) { window in
                    registry.registerWindow(window, for: request.id)
                }
                .frame(width: 0, height: 0)
            }
            .onAppear {
                registry.openNewWindow = { openWindow(value: $0) }
                registry.prepareWindow(request)
            }
            .onChange(of: store.projectURL) { _, projectURL in
                // Window restoration encodes the presented value, so it must record the
                // project the window actually shows — a window that switched projects
                // would otherwise restore the one it was first opened with. The id stays
                // untouched: it keys this window's registry entry.
                let path = projectURL?.standardizedFileURL.path
                guard request.projectPath != path else { return }
                request.projectPath = path
            }
            .onDisappear {
                registry.releaseWindow(request.id)
            }
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
