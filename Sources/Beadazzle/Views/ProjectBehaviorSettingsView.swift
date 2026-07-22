import SwiftUI

struct ProjectBehaviorSettingsPane: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var isConfirmingWorkspaceReset = false

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                LabeledContent("Consider stale after") {
                    Stepper(value: $store.staleCutoffDays, in: 1...365) {
                        Text("\(store.staleCutoffDays.formatted()) days")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Staleness")
            } footer: {
                Text("Controls which open beads appear in the Stale sidebar view.")
            }

            Section {
                Toggle(
                    "Hide parents whose unfinished children are all blocked",
                    isOn: $store.hidesParentsWithOnlyBlockedChildrenInReady
                )
            } header: {
                Text("Ready")
            } footer: {
                Text("Keeps blocked parent work out of Ready when none of its unfinished children can move forward.")
            }

            Section {
                Button("Reset Saved Workspace State", role: .destructive) {
                    isConfirmingWorkspaceReset = true
                }
                .disabled(store.projectURL == nil)
            } header: {
                Text("Saved Workspace")
            } footer: {
                Text("Beadazzle remembers this project's last view, filters, sort, selection, and expansion on this Mac. Resetting returns it to defaults.")
            }
        }
        .settingsGroupedForm()
        .confirmationDialog(
            "Reset saved workspace state?",
            isPresented: $isConfirmingWorkspaceReset
        ) {
            Button("Reset", role: .destructive) {
                store.resetSavedWorkspaceState()
            }
        } message: {
            Text("The remembered view, filters, sort, selection, and expansion for this project will be cleared.")
        }
    }
}
