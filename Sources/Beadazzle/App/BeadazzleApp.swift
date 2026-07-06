import AppKit
import SwiftUI

@main
struct BeadazzleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = BeadStore()
    @FocusedValue(\.beadNavigationAction) private var navigationAction

    var body: some Scene {
        WindowGroup("Beadazzle", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bead") {
                    NotificationCenter.default.post(name: .newBeadRequested, object: nil)
                }
                .keyboardShortcut("n")
            }

            BeadSaveCommands()

            CommandGroup(after: .importExport) {
                Button("Open Beads Project...") {
                    NotificationCenter.default.post(name: .openProjectRequested, object: nil)
                }
                .keyboardShortcut("o")

                Button("Refresh") {
                    NotificationCenter.default.post(name: .refreshRequested, object: nil)
                }
                .keyboardShortcut("r")
            }

            CommandMenu("Find") {
                Button("Find") {
                    NotificationCenter.default.post(name: .focusSearchRequested, object: nil)
                }
                .keyboardShortcut("f")
            }

            CommandMenu("Navigate") {
                Button(navigationAction?.title ?? "Back to Beads") {
                    navigationAction?.perform()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(navigationAction == nil)

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
