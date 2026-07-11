import AppKit
import SwiftUI

@main
struct BeadazzleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BeadStore()
    private let updaterController = UpdaterController()

    var body: some Scene {
        WindowGroup("Beadazzle", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                if let updater = updaterController.updater {
                    CheckForUpdatesView(updater: updater)
                }
            }

            WorkspaceCommands()
            BeadSaveCommands()
            ProjectSettingsCommands(store: store)

            CommandMenu("Navigate") {
                Button(BeadNavigationDirection.back.title) {
                    handleBackNavigation()
                }
                .keyboardShortcut(BeadNavigationDirection.back.shortcut)
                .disabled(!canNavigateBack)

                Button(BeadNavigationDirection.forward.title) {
                    store.goForward()
                }
                .keyboardShortcut(BeadNavigationDirection.forward.shortcut)
                .disabled(!store.canGoForward)

                Divider()

                Button("Expand Children") {
                    store.expandSelectedIssueChildren()
                }
                .disabled(!store.canExpandSelectedIssueChildren)

                Button("Collapse Children") {
                    store.collapseSelectedIssueChildren()
                }
                .disabled(!store.canCollapseSelectedIssueChildren)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environmentObject(updaterController)
        }
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)

        WindowGroup("Project Settings", for: URL.self) { projectURL in
            ProjectSettingsView(projectURL: projectURL.wrappedValue)
                .environment(store)
        }
        .defaultSize(width: 760, height: 500)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentMinSize)
    }

    private var canNavigateBack: Bool {
        store.canGoBack
    }

    private func handleBackNavigation() {
        store.goBack()
    }
}

enum WindowLayout {
    static let minWidth: CGFloat = 560
    static let minHeight: CGFloat = 520
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Beadazzle keeps its workspace window open.")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
