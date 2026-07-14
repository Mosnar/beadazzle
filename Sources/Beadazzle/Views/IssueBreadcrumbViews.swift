import SwiftUI

struct IssueCreationToolbarPresentation: Equatable {
    let projectName: String
    let draftTitle: String

    static let createButtonTitle = "Create"

    init(projectName: String, draftTitle: String) {
        self.projectName = projectName
        self.draftTitle = draftTitle.nilIfBlank ?? "Untitled bead"
    }

    var breadcrumbTitles: [String] {
        [projectName, draftTitle]
    }
}

struct IssueCreationToolbar: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let draft: IssueDraft
    let canCreate: Bool
    let isCreating: Bool
    let createAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        let presentation = IssueCreationToolbarPresentation(
            projectName: store.projectName,
            draftTitle: draft.title
        )

        HStack(spacing: 8) {
            BreadcrumbButton(presentation.projectName, systemImage: "folder", help: cancelButtonHelp) {
                cancelAction()
            }
            .disabled(isCreating)
            BreadcrumbSeparator()

            BreadcrumbIssueLabel(
                issueID: "New",
                title: presentation.draftTitle,
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

                Button(IssueCreationToolbarPresentation.createButtonTitle, action: createAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCreate)
                .help(createButtonHelp)
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
    private var workspace: BeadWorkspaceStore { store.workspace }
    let issue: BeadIssue
    let isDirty: Bool
    let canSave: Bool
    let saveAction: () -> Void
    let revertAction: () -> Void
    let requestClose: (BeadIssue) -> Void
    @State private var showingGateCreation = false
    @State private var pickerConfiguration: BeadPickerConfiguration?

    var body: some View {
        let canCreateGate = store.canCreateGate(blocking: issue)
        let completionTitle = store.completionActionTitle(for: [issue.id])
        let completionSystemImage = store.completionActionSystemImage(for: [issue.id])
        HStack(spacing: 8) {
            BreadcrumbButton(store.projectName, systemImage: "folder", help: "Back to beads") {
                store.clearSelection()
            }
            // The Gates crumb is dropped here — a task nested under a gate doesn't belong to
            // "Gates", and hiding it reclaims horizontal space.
            if workspace.selectedBookmark != .gates {
                BreadcrumbSeparator()
                BreadcrumbLabel(workspace.selectedBookmark.title, systemImage: workspace.selectedBookmark.systemImage)
            }

            if let parentIssue = store.parentIssue(for: issue.id) {
                let parentPresentation = ParentBeadPresentation(issue: parentIssue)
                BreadcrumbSeparator()
                BreadcrumbButton(
                    parentPresentation.id,
                    systemImage: store.statusSymbol(for: parentIssue.status),
                    iconTint: store.statusColor(for: parentIssue.status),
                    help: parentPresentation.helpText,
                    accessibilityLabel: parentPresentation.accessibilityLabel,
                    accessibilityValue: parentPresentation.accessibilityValue
                ) {
                    store.openIssueFromDetail(issueID: parentIssue.id)
                }
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
                        pickerConfiguration = .blockedBy(issue: issue)
                    } label: {
                        Label(
                            BlockingRelationshipDirection.blockedBy.actionTitle,
                            systemImage: BlockingRelationshipDirection.blockedBy.systemImage
                        )
                    }
                    Button {
                        pickerConfiguration = .blocks(issue: issue)
                    } label: {
                        Label(
                            BlockingRelationshipDirection.blocking.actionTitle,
                            systemImage: BlockingRelationshipDirection.blocking.systemImage
                        )
                    }
                    Divider()
                    if canCreateGate {
                        Button {
                            showingGateCreation = true
                        } label: {
                            Label("Create Gate...", systemImage: BeadIconography.genericGate)
                        }
                    }
                    Button {
                        requestClose(issue)
                    } label: {
                        Label(
                            completionTitle,
                            systemImage: completionSystemImage
                        )
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
                .popover(item: $pickerConfiguration, arrowEdge: .bottom) { configuration in
                    BeadPickerPopover(
                        configuration: configuration,
                        onApplied: { _ in },
                        onDismiss: {
                            pickerConfiguration = nil
                        }
                    )
                }
                .onChange(of: canCreateGate) { _, canCreateGate in
                    if !canCreateGate {
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
    var iconTint: Color?
    let help: String
    var accessibilityLabel: String?
    var accessibilityValue: String?
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    init(
        _ text: String,
        systemImage: String,
        iconTint: Color? = nil,
        help: String,
        accessibilityLabel: String? = nil,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.action = action
    }

    var body: some View {
        let isHighlighted = isHovered || isFocused

        Button(action: action) {
            Label {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isHighlighted ? .primary : .secondary)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconTint ?? (isHighlighted ? .primary : .secondary))
            }
            .font(.callout)
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
        .accessibilityLabel(accessibilityLabel ?? text)
        .accessibilityValue(accessibilityValue ?? "")
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
