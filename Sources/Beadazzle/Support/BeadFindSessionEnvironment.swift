import SwiftUI

extension View {
    /// Installs the window's in-bead find state. The four body fields need it to
    /// know whether they hold the focused match, and threading a rect down
    /// through `IssueBodySections` and `EditableTextSection` would make two
    /// views carry a parameter they otherwise have no interest in.
    func beadFindSessionEnvironment(_ session: BeadFindSession) -> some View {
        environment(session)
    }
}
