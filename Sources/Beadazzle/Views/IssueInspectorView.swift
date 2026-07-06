import SwiftUI

struct IssueInspector: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup("Properties") {
                IssueInspectorProperties(draft: $draft, includesStatus: true)
                InspectorRowDivider()

                InspectorValueRow(title: "Assignee", systemImage: "person.crop.circle", value: issue.assignee ?? "None")
                InspectorRowDivider()
                InspectorValueRow(title: "Owner", systemImage: "person.text.rectangle", value: issue.owner ?? "None")
                InspectorRowDivider()
                InspectorLabelsRow(
                    draft: $draft,
                    availableLabels: store.availableLabels
                )

                if issue.pinned {
                    InspectorRowDivider()
                    InspectorValueRow(title: "Pinned", systemImage: "pin", value: "Yes")
                }

                if issue.ephemeral {
                    InspectorRowDivider()
                    InspectorValueRow(title: "Ephemeral", systemImage: "sparkle", value: "Yes")
                }
            }

            InspectorGroup("Dates") {
                InspectorValueRow(title: "Created", systemImage: "calendar.badge.plus", value: BeadFormatters.displayDate(issue.createdAt))
                InspectorRowDivider()
                InspectorValueRow(title: "Updated", systemImage: "clock", value: BeadFormatters.displayDate(issue.updatedAt))
                InspectorRowDivider()
                InspectorDateRow(
                    title: "Due",
                    systemImage: "calendar",
                    value: $draft.dueAt,
                    includesDeferredShortcuts: false
                )
                InspectorRowDivider()
                InspectorDateRow(
                    title: "Deferred",
                    systemImage: "pause.circle",
                    value: $draft.deferUntil,
                    includesDeferredShortcuts: true
                )
            }

            InspectorGroup("Relationships") {
                InspectorValueRow(title: "Dependencies", systemImage: "arrow.down.right", value: "\(issue.dependencyCount)")
                InspectorRowDivider()
                InspectorValueRow(title: "Dependents", systemImage: "arrow.up.forward", value: "\(issue.dependentCount)")
                InspectorRowDivider()
                InspectorValueRow(title: "Comments", systemImage: "text.bubble", value: "\(max(issue.commentCount, store.comments(for: issue.id).count))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct IssueCreationInspector: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup("Properties") {
                IssueInspectorProperties(draft: $draft, includesStatus: false)
                InspectorRowDivider()
                InspectorLabelsRow(
                    draft: $draft,
                    availableLabels: store.availableLabels
                )
            }

            InspectorGroup("Dates") {
                InspectorDateRow(
                    title: "Due",
                    systemImage: "calendar",
                    value: $draft.dueAt,
                    includesDeferredShortcuts: false
                )
                InspectorRowDivider()
                InspectorDateRow(
                    title: "Deferred",
                    systemImage: "pause.circle",
                    value: $draft.deferUntil,
                    includesDeferredShortcuts: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
