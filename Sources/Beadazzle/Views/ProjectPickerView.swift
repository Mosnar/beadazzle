import AppKit
import SwiftUI

struct ProjectPickerButton: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var showsProjectPicker = false

    var body: some View {
        let state = projectState

        Button {
            showsProjectPicker.toggle()
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: state.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(store.projectName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Text(state.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(projectHelp)
        .accessibilityLabel("Current Project")
        .accessibilityValue(state.accessibilityValue(projectName: store.projectName))
        .accessibilityHint("Shows project picker")
        .popover(isPresented: $showsProjectPicker, arrowEdge: .trailing) {
            ProjectPickerPopover(isPresented: $showsProjectPicker)
        }
    }

    private var projectHelp: String {
        store.projectURL?.path ?? "Open a Beads project"
    }

    private var projectState: ProjectPickerButtonState {
        if store.projectURL == nil {
            return .noProject
        }
        if store.missingDataSourceURL != nil {
            return .needsSetup
        }
        return .ready
    }
}

private enum ProjectPickerButtonState {
    case noProject
    case ready
    case needsSetup

    var systemImage: String {
        switch self {
        case .noProject:
            "folder.badge.plus"
        case .ready:
            "folder"
        case .needsSetup:
            "folder.badge.questionmark"
        }
    }

    var subtitle: String {
        switch self {
        case .noProject:
            "Choose Folder"
        case .ready:
            "Project"
        case .needsSetup:
            "Needs Setup"
        }
    }

    func accessibilityValue(projectName: String) -> String {
        switch self {
        case .needsSetup:
            "\(projectName), needs setup"
        case .noProject, .ready:
            projectName
        }
    }
}

private enum ProjectPickerFocus: Hashable {
    case search
    case currentProject
    case recent(String)
    case addFolder
}

private struct ProjectPickerPopover: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.openWindow) private var openWindow
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectedItem: ProjectPickerFocus = .search
    @FocusState private var focusedRow: ProjectPickerFocus?

    private var currentProject: RecentProject? {
        guard let projectURL = store.projectURL else { return nil }
        return RecentProject(url: projectURL)
    }

    private var visibleRecentProjects: [RecentProject] {
        let recentProjects = store.recentProjects
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return recentProjects }

        return recentProjects.filter { project in
            project.name.localizedStandardContains(trimmedQuery)
                || project.path.localizedStandardContains(trimmedQuery)
        }
    }

    private var focusOrder: [ProjectPickerFocus] {
        (currentProject == nil ? [] : [.currentProject]) + visibleRecentProjects.map { .recent($0.id) } + [.addFolder]
    }

    private var visibleRecentProjectIDs: [String] {
        visibleRecentProjects.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectSearchField(
                text: $query,
                isFocused: selectedItem == .search
            ) {
                selectItem(.search)
            } moveDown: {
                focusFirstMenuItem()
            } dismiss: {
                isPresented = false
            }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 13)

            ProjectPickerSectionLabel("Current Project")
                .padding(.horizontal, 20)
                .padding(.bottom, 7)

            if let currentProject {
                CurrentProjectRow(
                    project: currentProject,
                    isFocused: selectedItem == .currentProject,
                    focusedItem: $focusedRow,
                    focusID: .currentProject
                ) {
                    openProjectSettings()
                } moveUp: {
                    selectItem(.search)
                } moveDown: {
                    moveFocusDown()
                }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 13)
            } else {
                Text("No Project")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 13)
            }

            if !visibleRecentProjects.isEmpty || !query.isEmpty {
                ProjectPickerDivider()

                ProjectPickerSectionLabel("Recent Projects")
                    .padding(.horizontal, 20)
                    .padding(.top, 9)
                    .padding(.bottom, 5)

                if visibleRecentProjects.isEmpty {
                    Text("No Matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 1) {
                        ForEach(visibleRecentProjects) { project in
                            let focusID = ProjectPickerFocus.recent(project.id)
                            RecentProjectRow(
                                project: project,
                                isCurrent: project.id == currentProject?.id,
                                isFocused: selectedItem == focusID,
                                focusedItem: $focusedRow,
                                focusID: focusID
                            ) {
                                store.openRecentProject(project)
                                isPresented = false
                            } remove: {
                                selectItem(focusAfterRemoving(project))
                                store.removeRecentProject(project)
                            } moveUp: {
                                moveFocusUp()
                            } moveDown: {
                                moveFocusDown()
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 9)
                }
            }

            ProjectPickerDivider()

            VStack(spacing: 1) {
                ProjectActionRow(
                    title: "Add Folder...",
                    isFocused: selectedItem == .addFolder,
                    focusedItem: $focusedRow,
                    focusID: .addFolder
                ) {
                    chooseProjectFolder()
                } moveUp: {
                    moveFocusUp()
                } moveDown: {
                    moveFocusDown()
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
        }
        .frame(width: 338)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onAppear {
            selectItem(.search)
        }
        .onChange(of: focusedRow) { _, newFocusedRow in
            if let newFocusedRow {
                selectedItem = newFocusedRow
            }
        }
        .onChange(of: visibleRecentProjectIDs) {
            repairFocusedItem()
        }
        .onDisappear {
            query = ""
        }
    }

    private func chooseProjectFolder() {
        guard let url = PanelService.chooseProjectFolder() else { return }
        isPresented = false
        store.openProject(url)
    }

    private func openProjectSettings() {
        guard let projectURL = store.projectURL else { return }
        openWindow(value: projectURL.standardizedFileURL)
        isPresented = false
    }

    private func focusFirstMenuItem() {
        selectItem(focusOrder.first ?? .search)
    }

    private func moveFocusDown() {
        guard selectedItem != .search else {
            focusFirstMenuItem()
            return
        }

        guard let currentIndex = focusOrder.firstIndex(of: selectedItem) else {
            focusFirstMenuItem()
            return
        }

        let nextIndex = focusOrder.index(after: currentIndex)
        if nextIndex < focusOrder.endIndex {
            selectItem(focusOrder[nextIndex])
        }
    }

    private func moveFocusUp() {
        guard selectedItem != .search else { return }

        guard let currentIndex = focusOrder.firstIndex(of: selectedItem) else {
            selectItem(.search)
            return
        }

        if currentIndex == focusOrder.startIndex {
            selectItem(.search)
        } else {
            selectItem(focusOrder[focusOrder.index(before: currentIndex)])
        }
    }

    private func selectItem(_ item: ProjectPickerFocus) {
        selectedItem = item
        focusedRow = item == .search ? nil : item
    }

    private func focusAfterRemoving(_ project: RecentProject) -> ProjectPickerFocus {
        let removedFocus = ProjectPickerFocus.recent(project.id)
        let remainingOrder = focusOrder.filter { $0 != removedFocus }
        guard let removedIndex = focusOrder.firstIndex(of: removedFocus) else {
            return remainingOrder.first ?? .search
        }

        let nextIndex = min(removedIndex, remainingOrder.index(before: remainingOrder.endIndex))
        return remainingOrder[nextIndex]
    }

    private func repairFocusedItem() {
        guard selectedItem != .search, !focusOrder.contains(selectedItem) else { return }
        selectItem(focusOrder.first ?? .search)
    }
}

private enum KeyCode {
    static let escape: UInt16 = 53
    static let downArrow: UInt16 = 125
}

private struct ProjectSearchField: View {
    @Binding var text: String
    let isFocused: Bool
    let focus: () -> Void
    let moveDown: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            ProjectSearchTextField(
                text: $text,
                isFocused: isFocused,
                focus: focus,
                moveDown: moveDown,
                dismiss: dismiss
            )
            .frame(height: 18)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(searchFieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.04), lineWidth: 0.5)
        }
    }

    private var searchFieldFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.56)
    }
}

private struct ProjectSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let focus: () -> Void
    let moveDown: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ProjectSearchNSTextField {
        let textField = ProjectSearchNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = "Find"
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.placeholderAttributedString = NSAttributedString(
            string: "Find",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.cell?.isScrollable = true
        textField.cell?.usesSingleLineMode = true
        textField.onFocus = focus
        textField.onDownArrow = moveDown
        textField.onEscape = dismiss
        textField.wantsFocus = isFocused
        return textField
    }

    func updateNSView(_ nsView: ProjectSearchNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onFocus = focus
        nsView.onDownArrow = moveDown
        nsView.onEscape = dismiss
        nsView.wantsFocus = isFocused
        nsView.focusIfNeeded()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ProjectSearchTextField

        init(_ parent: ProjectSearchTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.moveDown()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.dismiss()
                return true
            default:
                return false
            }
        }
    }
}

private final class ProjectSearchNSTextField: NSTextField {
    var wantsFocus = false
    var onFocus: () -> Void = {}
    var onDownArrow: () -> Void = {}
    var onEscape: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocus()
        }
        return didBecomeFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        let ignoredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        guard event.modifierFlags.intersection(ignoredModifiers).isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case KeyCode.downArrow:
            onDownArrow()
        case KeyCode.escape:
            onEscape()
        default:
            super.keyDown(with: event)
        }
    }

    func focusIfNeeded() {
        guard wantsFocus, window != nil, currentEditor() == nil else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.wantsFocus, self.currentEditor() == nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}

private struct ProjectPickerSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct CurrentProjectRow: View {
    let project: RecentProject
    let isFocused: Bool
    let focusedItem: FocusState<ProjectPickerFocus?>.Binding
    let focusID: ProjectPickerFocus
    let openSettings: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(rowForeground)
                .frame(width: 38)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(rowForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("Active Project")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? .white.opacity(0.78) : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: openSettings) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(rowForeground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .help("Project Settings")
            .accessibilityLabel("Project Settings")
        }
        .padding(.horizontal, 7)
        .frame(height: 48)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .focusable()
        .focused(focusedItem, equals: focusID)
        .onKeyPress(.upArrow) {
            moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveDown()
            return .handled
        }
        .onKeyPress(.return) {
            openSettings()
            return .handled
        }
        .onHover { isHovered = $0 }
        .help(project.path)
    }

    private var rowBackground: Color {
        isActive ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }

    private var rowForeground: Color {
        isActive ? .white : .primary
    }

    private var isActive: Bool {
        isHovered || isFocused
    }
}

private struct RecentProjectRow: View {
    let project: RecentProject
    let isCurrent: Bool
    let isFocused: Bool
    let focusedItem: FocusState<ProjectPickerFocus?>.Binding
    let focusID: ProjectPickerFocus
    let open: () -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                open()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(rowForeground)
                        .opacity(isCurrent ? 1 : 0)
                        .frame(width: 12)
                        .accessibilityHidden(true)

                    Label(project.name, systemImage: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(rowForeground)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .focusable()
            .focused(focusedItem, equals: focusID)
            .onKeyPress(.upArrow) {
                moveUp()
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveDown()
                return .handled
            }
            .onKeyPress(.return) {
                open()
                return .handled
            }
            .onDeleteCommand {
                remove()
            }
            .help(project.path)
            .accessibilityLabel(project.name)
            .accessibilityValue(isCurrent ? "Current Project" : "")
            .accessibilityHint("Opens the project. Press Delete to remove it from Recents.")

            Button(role: .destructive) {
                remove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? .white.opacity(0.78) : .secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .help("Remove from Recents")
            .accessibilityLabel("Remove \(project.name) from Recents")
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        isActive ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }

    private var rowForeground: Color {
        isActive ? .white : .primary
    }

    private var isActive: Bool {
        isHovered || isFocused
    }
}

private struct ProjectActionRow: View {
    let title: String
    let isFocused: Bool
    let focusedItem: FocusState<ProjectPickerFocus?>.Binding
    let focusID: ProjectPickerFocus
    let action: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(rowForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background(rowBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focusedItem, equals: focusID)
        .onKeyPress(.upArrow) {
            moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveDown()
            return .handled
        }
        .onKeyPress(.return) {
            action()
            return .handled
        }
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        isActive ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }

    private var rowForeground: Color {
        isActive ? .white : .primary
    }

    private var isActive: Bool {
        isHovered || isFocused
    }
}

private struct ProjectPickerDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 20)
    }
}
