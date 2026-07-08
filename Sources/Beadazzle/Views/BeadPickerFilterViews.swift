import SwiftUI

struct BeadPickerFilterMenu<Content: View>: View {
    let title: String
    let systemImage: String
    let activeCount: Int
    let content: Content

    init(
        title: String,
        systemImage: String,
        activeCount: Int,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.activeCount = activeCount
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Label(activeCount > 0 ? "\(title) \(activeCount)" : title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

struct BeadPickerFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct BeadPickerLabelFilterControl: View {
    @Binding var selectedLabels: Set<String>
    let availableLabels: [String]
    @State private var isPresented = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var allLabels: [String] {
        Array(Set(availableLabels).union(selectedLabels)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var filteredLabels: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allLabels }
        return allLabels.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(selectedLabels.isEmpty ? "Labels" : "Labels \(selectedLabels.count)", systemImage: "tag.circle")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .onChange(of: isPresented) { _, isPresented in
            if !isPresented {
                searchText = ""
            }
        }
        .task(id: isPresented) {
            guard isPresented else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            isSearchFocused = true
        }
        .accessibilityLabel("Labels")
        .accessibilityValue(selectedLabels.isEmpty ? "None" : selectedLabels.sorted().joined(separator: ", "))
        .accessibilityHint("Opens label filters")
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search labels", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isSearchFocused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            BeadPickerDivider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    if filteredLabels.isEmpty {
                        Text("No matching labels")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    } else {
                        ForEach(filteredLabels, id: \.self) { label in
                            labelRow(label)
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 218)

            BeadPickerDivider()

            HStack(spacing: 8) {
                Text(selectedLabels.isEmpty ? "No labels selected" : "\(selectedLabels.count.formatted()) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Clear") {
                    selectedLabels.removeAll()
                }
                .controlSize(.small)
                .disabled(selectedLabels.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
    }

    private func labelRow(_ label: String) -> some View {
        let isSelected = selectedLabels.contains(label)
        return Button {
            toggle(label)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? BeadPickerChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: BeadPickerChrome.rowCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func toggle(_ label: String) {
        if selectedLabels.contains(label) {
            selectedLabels.remove(label)
        } else {
            selectedLabels.insert(label)
        }
    }
}
