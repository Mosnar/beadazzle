import AppKit
import SwiftUI

struct WorkspaceMouseNavigationBridge: NSViewRepresentable {
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    func makeNSView(context: Context) -> MouseNavigationBridgeView {
        let view = MouseNavigationBridgeView()
        view.canGoBack = canGoBack
        view.canGoForward = canGoForward
        view.goBack = goBack
        view.goForward = goForward
        return view
    }

    func updateNSView(_ nsView: MouseNavigationBridgeView, context: Context) {
        nsView.canGoBack = canGoBack
        nsView.canGoForward = canGoForward
        nsView.goBack = goBack
        nsView.goForward = goForward
        nsView.installMonitorIfNeeded()
    }

    final class MouseNavigationBridgeView: NSView {
        var canGoBack = false
        var canGoForward = false
        var goBack: (() -> Void)?
        var goForward: (() -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                guard let window = self.window, event.window === window else { return event }

                switch event.buttonNumber {
                case 3 where self.canGoBack:
                    self.goBack?()
                    return nil
                case 4 where self.canGoForward:
                    self.goForward?()
                    return nil
                default:
                    return event
                }
            }
        }

        private func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
