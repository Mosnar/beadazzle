import SwiftUI

struct BeadNavigationAction {
    let title: String
    let perform: () -> Void
}

private struct BeadNavigationActionKey: FocusedValueKey {
    typealias Value = BeadNavigationAction
}

extension FocusedValues {
    var beadNavigationAction: BeadNavigationAction? {
        get { self[BeadNavigationActionKey.self] }
        set { self[BeadNavigationActionKey.self] = newValue }
    }
}

