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
                .beadStoreEnvironment(store)
                .frame(minWidth: WindowLayout.minWidth, minHeight: WindowLayout.minHeight)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AboutCommands()

            CommandGroup(after: .appInfo) {
                if let updater = updaterController.updater {
                    CheckForUpdatesView(updater: updater)
                }
            }

            WorkspaceCommands()
            BeadSaveCommands()
            AppSettingsCommands()
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

        Window("About Beadazzle", id: AboutBeadazzleView.windowID) {
            AboutBeadazzleView()
        }
        .defaultSize(width: 640, height: 320)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window(
            AboutDisclosure.acknowledgments.title,
            id: AboutDisclosure.acknowledgments.windowID
        ) {
            AboutDisclosureView(disclosure: .acknowledgments)
                .frame(minWidth: 560, minHeight: 380)
        }
        .defaultSize(width: 780, height: 560)
        .windowResizability(.contentMinSize)

        Window(
            AboutDisclosure.license.title,
            id: AboutDisclosure.license.windowID
        ) {
            AboutDisclosureView(disclosure: .license)
                .frame(minWidth: 560, minHeight: 380)
        }
        .defaultSize(width: 700, height: 520)
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView()
                .beadStoreEnvironment(store)
                .environmentObject(updaterController)
        }
        .defaultSize(
            width: SettingsWindowLayout.appDefaultWidth,
            height: SettingsWindowLayout.appDefaultHeight
        )
        .windowResizability(.contentMinSize)

        WindowGroup("Project Settings", for: URL.self) { projectURL in
            ProjectSettingsView(projectURL: projectURL.wrappedValue)
                .beadStoreEnvironment(store)
        }
        .defaultSize(
            width: SettingsWindowLayout.projectDefaultWidth,
            height: SettingsWindowLayout.projectDefaultHeight
        )
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
