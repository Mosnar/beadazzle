import AppKit
import SwiftUI

@main
struct BeadazzleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var registry = BeadWorkspaceWindowRegistry()
    private let updaterController = UpdaterController()

    var body: some Scene {
        // Value-parameterized so `openWindow(value:)` can open a second workspace window
        // on another project. Windows created without a value — at launch, or from the
        // Window menu — get a fresh identity and no project from `defaultValue`.
        WindowGroup("Beadazzle", id: "main", for: BeadWorkspaceWindowRequest.self) { $request in
            WorkspaceWindowRoot(registry: registry, request: $request)
        } defaultValue: {
            BeadWorkspaceWindowRequest()
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
            ProjectSettingsCommands(registry: registry)

            CommandMenu("Navigate") {
                BeadNavigationMenuItems()
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
            // App preferences are shared, so any live store can edit them; reading through
            // the frontmost window's keeps project-derived fields (assignee suggestions)
            // meaningful.
            SettingsView()
                .beadStoreEnvironment(registry.auxiliaryStore())
                .environment(registry)
                .environmentObject(updaterController)
        }
        .defaultSize(
            width: SettingsWindowLayout.appDefaultWidth,
            height: SettingsWindowLayout.appDefaultHeight
        )
        .windowResizability(.contentMinSize)

        WindowGroup("Project Settings", for: URL.self) { projectURL in
            ProjectSettingsView(projectURL: projectURL.wrappedValue)
                .beadStoreEnvironment(registry.store(forProject: projectURL.wrappedValue))
                .environment(registry)
        }
        .defaultSize(
            width: SettingsWindowLayout.projectDefaultWidth,
            height: SettingsWindowLayout.projectDefaultHeight
        )
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
