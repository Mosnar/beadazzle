import SwiftUI

struct IssueCreationToolbar: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let draft: IssueDraft
    let canCreate: Bool
    let isCreating: Bool
    let createAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BreadcrumbButton(store.projectName, systemImage: "folder", help: cancelButtonHelp) {
                cancelAction()
            }
            .disabled(isCreating)
            BreadcrumbSeparator()
            BreadcrumbLabel(store.selectedBookmark.title, systemImage: store.selectedBookmark.systemImage)
            BreadcrumbSeparator()

            BreadcrumbIssueLabel(
                issueID: "New",
                title: draft.title.nilIfBlank ?? "Untitled bead",
                statusDescription: "new",
                statusSymbol: "plus.circle.fill",
                statusColor: .green
            )
            .layoutPriority(-1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button("Discard") {
                    cancelAction()
                }
                .controlSize(.small)
                .disabled(isCreating)
                .help(cancelButtonHelp)

                Button {
                    createAction()
                } label: {
                    Label("Create Bead", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(canCreate ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canCreate)
                .help(createButtonHelp)
                .accessibilityLabel("Create Bead")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var createButtonHelp: String {
        if isCreating {
            return "Creating bead..."
        }
        return canCreate ? "Create bead" : "Add a title to create bead"
    }

    private var cancelButtonHelp: String {
        isCreating ? "Creating bead..." : "Cancel new bead"
    }
}

struct IssueBreadcrumbBar: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    let isDirty: Bool
    let canSave: Bool
    let saveAction: () -> Void
    let revertAction: () -> Void
    let requestClose: (BeadIssue) -> Void
    @State private var showingGateCreation = false

    var body: some View {
        HStack(spacing: 8) {
            BreadcrumbButton(store.projectName, systemImage: "folder", help: "Back to beads") {
                store.clearSelection()
            }
            // The Gates crumb is dropped here — a task nested under a gate doesn't belong to
            // "Gates", and hiding it reclaims horizontal space.
            if store.selectedBookmark != .gates {
                BreadcrumbSeparator()
                BreadcrumbLabel(store.selectedBookmark.title, systemImage: store.selectedBookmark.systemImage)
            }
            BreadcrumbSeparator()

            BreadcrumbIssueLabel(
                issueID: issue.id,
                title: issue.title,
                statusDescription: issue.status,
                statusSymbol: store.statusSymbol(for: issue.status),
                statusColor: store.statusColor(for: issue.status)
            )
            .layoutPriority(-1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if isDirty {
                    Button("Revert") {
                        revertAction()
                    }
                    .controlSize(.small)

                    Button {
                        saveAction()
                    } label: {
                        Label("Save Changes", systemImage: "checkmark")
                    }
                    .controlSize(.small)
                    .disabled(!canSave)
                }

                Button {
                    IssueClipboard.copyIssueID(issue.id)
                } label: {
                    Label("Copy Bead ID", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy \(issue.id)")
                .accessibilityLabel("Copy Bead ID")

                Menu {
                    Button {
                        showingGateCreation = true
                    } label: {
                        Label("Create Gate...", systemImage: "flag.checkered")
                    }
                    Button {
                        requestClose(issue)
                    } label: {
                        Label("Close Bead...", systemImage: "checkmark.circle")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel("More")
                .popover(isPresented: $showingGateCreation, arrowEdge: .bottom) {
                    GateCreationForm(blockedIssueID: issue.id, blockedTitle: issue.title) {
                        showingGateCreation = false
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BreadcrumbIssueLabel: View {
    let issueID: String
    let title: String
    let statusDescription: String
    let statusSymbol: String
    let statusColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 16, alignment: .center)

            Text(issueID)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .frame(minWidth: 0, alignment: .leading)
        .help("\(issueID) \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issueID) \(title), status: \(statusDescription)")
    }
}

struct BreadcrumbLabel: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, BreadcrumbChrome.horizontalPadding)
        .padding(.vertical, BreadcrumbChrome.verticalPadding)
        .accessibilityLabel(text)
    }
}

struct BreadcrumbButton: View {
    let text: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    init(_ text: String, systemImage: String, help: String, action: @escaping () -> Void) {
        self.text = text
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        let isHighlighted = isHovered || isFocused

        Button(action: action) {
            Label {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.callout)
            .foregroundStyle(isHighlighted ? .primary : .secondary)
            .padding(.horizontal, BreadcrumbChrome.horizontalPadding)
            .padding(.vertical, BreadcrumbChrome.verticalPadding)
            .contentShape(RoundedRectangle(cornerRadius: BreadcrumbChrome.cornerRadius))
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: BreadcrumbChrome.cornerRadius)
                        .fill(.quaternary.opacity(0.45))
                }
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: BreadcrumbChrome.cornerRadius)
                        .stroke(.tint.opacity(0.75), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityHint(help)
    }
}

private enum BreadcrumbChrome {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let cornerRadius: CGFloat = 7
}

struct BreadcrumbSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
