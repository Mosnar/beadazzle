import AppKit
import SwiftUI

struct ProjectStatePropertyValuesPane: View {
    let dimension: String?
    let displayName: String?
    let catalog: BeadStateValueCatalog
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Available Values")
                    .font(.headline)

                Spacer(minLength: 8)

                if dimension != nil {
                    Text(valueCountDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            List(selection: $selection) {
                ForEach(catalog.active) { value in
                    valueRow(value)
                }

                if !catalog.archived.isEmpty {
                    Section {
                        ForEach(catalog.archived) { value in
                            valueRow(value)
                        }
                    } header: {
                        Text("Archived Values")
                            .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .id(dimension)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if dimension == nil {
                    ContentUnavailableView(
                        "Select a Property",
                        systemImage: "slider.horizontal.3",
                        description: Text("Choose a property to review the values available in this project.")
                    )
                } else if catalog.count == 0 {
                    ContentUnavailableView(
                        "No Recorded Values",
                        systemImage: "tray",
                        description: Text("Enter the first value from a bead's Properties section.")
                    )
                }
            }
            .accessibilityLabel(displayName.map { "Available values for \($0)" } ?? "Available Values")
        }
        .onChange(of: dimension) {
            selection = nil
        }
        .onChange(of: catalog) { _, newCatalog in
            guard let selection else { return }
            let stillExists = newCatalog.active.contains { $0.value == selection }
                || newCatalog.archived.contains { $0.value == selection }
            if !stillExists {
                self.selection = nil
            }
        }
    }

    private func valueRow(_ value: BeadStateValuePresentation) -> some View {
        ProjectStatePropertyValueRow(
            dimension: dimension ?? "",
            value: value,
            isSelected: selection == value.value
        )
        .tag(value.value)
    }

    private var valueCountDescription: String {
        "\(catalog.count.formatted()) \(catalog.count == 1 ? "value" : "values")"
    }
}

private struct ProjectStatePropertyValueRow: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.openWindow) private var openWindow
    let dimension: String
    let value: BeadStateValuePresentation
    let isSelected: Bool
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftDisplayName = ""
    @FocusState private var displayNameIsFocused: Bool

    private var showsControls: Bool {
        !isRenaming && (isHovered || isSelected)
    }

    var body: some View {
        let usageCount = store.stateValueUsageCount(for: value.value, in: dimension)
        let usageDescription = formattedUsageCount(usageCount)

        HStack(spacing: 8) {
            Group {
                if isRenaming {
                    TextField("Display Name", text: $draftDisplayName)
                        .focused($displayNameIsFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: displayNameIsFocused) { oldValue, newValue in
                            if oldValue, !newValue, isRenaming {
                                commitRename()
                            }
                        }
                } else {
                    Text(value.displayName)
                        .foregroundStyle(value.isArchived ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if usageCount > 0 {
                Button(action: showBeads) {
                    Text(usageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityHidden(true)
                .help("Show \(usageDescription)")
            } else {
                Text(usageDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }

            Menu {
                actions(usageCount: usageCount, usageDescription: usageDescription)
            } label: {
                Label("Actions for \(value.displayName)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(true)
            .help("Actions for \(value.displayName)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovered in
            if self.isHovered != isHovered {
                self.isHovered = isHovered
            }
        }
        .contextMenu {
            actions(usageCount: usageCount, usageDescription: usageDescription)
        }
        .task(id: isRenaming) {
            guard isRenaming else { return }
            await Task.yield()
            guard !Task.isCancelled, isRenaming else { return }
            displayNameIsFocused = true
        }
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(accessibilityLabel(usageDescription: usageDescription))
        .accessibilityActions {
            if usageCount > 0 {
                Button("Show \(usageDescription)", action: showBeads)
            }
            Button("Edit Display Name", action: beginRename)
            if value.displayName != value.value {
                Button("Reset Display Name", action: resetDisplayName)
            }
            Button(value.isArchived ? "Restore Value" : "Archive Value", action: toggleArchived)
        }
        .help("Stored value: \(value.value)")
    }

    @ViewBuilder
    private func actions(usageCount: Int, usageDescription: String) -> some View {
        if usageCount > 0 {
            Button(action: showBeads) {
                Label("Show \(usageDescription)", systemImage: "line.3.horizontal.decrease.circle")
            }

            Divider()
        }

        Button(action: beginRename) {
            Label("Edit Display Name…", systemImage: "pencil")
        }

        if value.displayName != value.value {
            Button(action: resetDisplayName) {
                Label("Reset Display Name", systemImage: "arrow.counterclockwise")
            }
        }

        Divider()

        Button(action: toggleArchived) {
            if value.isArchived {
                Label("Restore Value", systemImage: "arrow.uturn.backward.circle")
            } else {
                Label("Archive Value", systemImage: "archivebox")
            }
        }
    }

    private func formattedUsageCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "bead" : "beads")"
    }

    private func accessibilityLabel(usageDescription: String) -> String {
        var components = [value.displayName, usageDescription]
        if value.displayName != value.value {
            components.append("stored value \(value.value)")
        }
        if value.isArchived {
            components.append("archived")
        }
        return components.joined(separator: ", ")
    }

    private func beginRename() {
        draftDisplayName = value.displayName
        isRenaming = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        let displayName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty,
              !displayName.contains(where: \Character.isNewline),
              store.setStateValueDisplayName(displayName, for: value.value, in: dimension) else {
            cancelRename()
            return
        }
        finishRename()
    }

    private func cancelRename() {
        guard isRenaming else { return }
        draftDisplayName = value.displayName
        isRenaming = false
        displayNameIsFocused = false
    }

    private func finishRename() {
        isRenaming = false
        displayNameIsFocused = false
    }

    private func resetDisplayName() {
        _ = store.setStateValueDisplayName(value.value, for: value.value, in: dimension)
    }

    private func toggleArchived() {
        store.setStateValue(value.value, in: dimension, isArchived: !value.isArchived)
    }

    private func showBeads() {
        guard store.showBeads(withStateValue: value.value, in: dimension) else { return }

        if let mainWindow = NSApp.windows.first(where: { $0.title == "Beadazzle" }) {
            if mainWindow.isMiniaturized {
                mainWindow.deminiaturize(nil)
            }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
