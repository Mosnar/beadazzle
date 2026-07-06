import SwiftUI

struct BeadSaveAction {
    let title: String
    let perform: () -> Void
}

private struct BeadSaveActionKey: FocusedValueKey {
    typealias Value = BeadSaveAction
}

extension FocusedValues {
    var beadSaveAction: BeadSaveAction? {
        get { self[BeadSaveActionKey.self] }
        set { self[BeadSaveActionKey.self] = newValue }
    }
}

struct BeadSaveCommands: Commands {
    @FocusedValue(\.beadSaveAction) private var saveAction

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(saveAction?.title ?? "Save") {
                saveAction?.perform()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(saveAction == nil)
        }
    }
}
