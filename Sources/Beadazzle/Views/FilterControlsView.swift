import SwiftUI

private enum FilterControlMetrics {
    static let chipRowHeight: CGFloat = 26
}

struct FilterMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        Menu {
            if store.hasActiveFilters {
                Button {
                    deferStoreUpdate {
                        store.clearFilters()
                    }
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }

                Divider()
            }

            Section("Status") {
                ForEach(store.statusCounts, id: \.0) { status, count in
                    Toggle(isOn: statusBinding(status)) {
                        MenuRowLabel(
                            title: status,
                            count: count,
                            systemImage: store.statusSymbol(for: status)
                        )
                    }
                }
            }

            Section("Type") {
                ForEach(store.typeCounts, id: \.0) { type, count in
                    Toggle(isOn: typeBinding(type)) {
                        MenuRowLabel(title: type, count: count, systemImage: "tag")
                    }
                }
            }

            Section("Priority") {
                ForEach(store.priorityCounts, id: \.0) { priority, count in
                    Toggle(isOn: priorityBinding(priority)) {
                        MenuRowLabel(title: "P\(priority)", count: count, systemImage: "exclamationmark.triangle")
                    }
                }
            }

            if !store.labelCounts.isEmpty {
                Menu("Labels") {
                    ForEach(store.labelCounts, id: \.0) { label, count in
                        Toggle(isOn: labelBinding(label)) {
                            MenuRowLabel(title: label, count: count, systemImage: "tag")
                        }
                    }
                }
            }
        } label: {
            Label(filterTitle, systemImage: filterIcon)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private var filterTitle: String {
        store.hasActiveFilters ? "Filters (\(store.activeFilterCount))" : "Filters"
    }

    private var filterIcon: String {
        store.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    private func statusBinding(_ status: String) -> Binding<Bool> {
        Binding(
            get: { store.statusFilters.contains(status) },
            set: { isOn in
                deferStoreUpdate {
                    store.setStatusFilter(status, isOn: isOn)
                }
            }
        )
    }

    private func typeBinding(_ type: String) -> Binding<Bool> {
        Binding(
            get: { store.typeFilters.contains(type) },
            set: { isOn in
                deferStoreUpdate {
                    store.setTypeFilter(type, isOn: isOn)
                }
            }
        )
    }

    private func priorityBinding(_ priority: Int) -> Binding<Bool> {
        Binding(
            get: { store.priorityFilters.contains(priority) },
            set: { isOn in
                deferStoreUpdate {
                    store.setPriorityFilter(priority, isOn: isOn)
                }
            }
        )
    }

    private func labelBinding(_ label: String) -> Binding<Bool> {
        Binding(
            get: { store.labelFilters.contains(label) },
            set: { isOn in
                deferStoreUpdate {
                    store.setLabelFilter(label, isOn: isOn)
                }
            }
        )
    }

    private func deferStoreUpdate(_ action: @escaping @MainActor () -> Void) {
        action()
    }
}

struct ActiveFilterChipsView: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(store.statusFilters.sorted(), id: \.self) { status in
                    FilterChip(
                        title: status,
                        systemImage: store.statusSymbol(for: status),
                        tint: store.statusColor(for: status)
                    ) {
                        deferStoreUpdate {
                            store.setStatusFilter(status, isOn: false)
                        }
                    }
                }

                ForEach(store.typeFilters.sorted(), id: \.self) { type in
                    FilterChip(title: type, systemImage: "tag") {
                        deferStoreUpdate {
                            store.setTypeFilter(type, isOn: false)
                        }
                    }
                }

                ForEach(store.priorityFilters.sorted(), id: \.self) { priority in
                    FilterChip(title: "P\(priority)", systemImage: "exclamationmark.triangle") {
                        deferStoreUpdate {
                            store.setPriorityFilter(priority, isOn: false)
                        }
                    }
                }

                ForEach(store.labelFilters.sorted(), id: \.self) { label in
                    FilterChip(title: label, systemImage: "tag") {
                        deferStoreUpdate {
                            store.setLabelFilter(label, isOn: false)
                        }
                    }
                }

                Button {
                    deferStoreUpdate {
                        store.clearFilters()
                    }
                } label: {
                    Text("Clear")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
            }
            .padding(.vertical, 1)
            .frame(height: FilterControlMetrics.chipRowHeight, alignment: .center)
        }
        .frame(height: FilterControlMetrics.chipRowHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func deferStoreUpdate(_ action: @escaping @MainActor () -> Void) {
        action()
    }
}

private struct MenuRowLabel: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        Label("\(title) (\(count.formatted()))", systemImage: systemImage)
    }
}

private struct FilterChip: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)

                Text(title)
                    .lineLimit(1)

                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
