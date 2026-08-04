import SwiftUI

struct ProjectDoltSyncFailureDetailsSheet: View {
    let outcome: ProjectDoltSyncOutcome

    private var details: BeadCommandFailureDetails {
        BeadCommandFailureDetails(command: outcome.command, output: outcome.output)
    }

    var body: some View {
        BeadCommandFailureDetailsSheet(
            title: outcome.title,
            message: outcome.detail,
            details: details
        )
    }
}
