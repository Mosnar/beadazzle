import SwiftUI

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Beadazzle") {
                openWindow(id: AboutBeadazzleView.windowID)
            }
        }
    }
}
