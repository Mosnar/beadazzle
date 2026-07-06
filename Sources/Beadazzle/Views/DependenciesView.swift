import SwiftUI

struct DependenciesView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    @State private var isAddingDependency = false
    @State private var dependsOnID = ""
    @State private var dependencyType = ""

    var body: some View {
        let dependencies = store.dependencies(for: issue.id)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Relationships")
                    .font(.headline)

                Text(relationshipCount.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        isAddingDependency.toggle()
                    }
                } label: {
                    Label(isAddingDependency ? "Cancel" : "Add Dependency", systemImage: isAddingDependency ? "xmark" : "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if isAddingDependency {
                LazyVGrid(columns: controlColumns, alignment: .leading, spacing: 8) {
                    if !store.availableDependencyTypes.isEmpty {
                        Menu {
                            ForEach(store.availableDependencyTypes, id: \.self) { type in
                                Button(type) {
                                    dependencyType = type
                                }
                            }
                        } label: {
                            Label("Known Types", systemImage: "chevron.down.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .menuStyle(.button)
                    }

                    TextField("Type", text: $dependencyType)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 0, maxWidth: .infinity)

                    TextField("Depends on ID", text: $dependsOnID)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 0, maxWidth: .infinity)

                    Button {
                        let dependsOnID = normalizedDependsOnID
                        let dependencyType = normalizedDependencyType
                        Task {
                            if await store.addDependency(issueID: issue.id, dependsOnID: dependsOnID, type: dependencyType) {
                                self.dependsOnID = ""
                                isAddingDependency = false
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(normalizedDependsOnID.isEmpty || normalizedDependencyType.isEmpty)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }

            if dependencies.isEmpty {
                Text("No dependencies or dependents.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(dependencies) { dependency in
                        DependencyRow(issueID: issue.id, dependency: dependency)
                        Divider()
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onAppear {
            chooseDefaultDependencyTypeIfNeeded()
        }
        .onChange(of: store.availableDependencyTypes) {
            chooseDefaultDependencyTypeIfNeeded()
        }
        .onChange(of: issue.id) {
            isAddingDependency = false
            dependsOnID = ""
            dependencyType = ""
            chooseDefaultDependencyTypeIfNeeded()
        }
    }

    private var normalizedDependsOnID: String {
        dependsOnID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDependencyType: String {
        dependencyType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var relationshipCount: Int {
        issue.dependencyCount + issue.dependentCount
    }

    private func chooseDefaultDependencyTypeIfNeeded() {
        guard normalizedDependencyType.isEmpty, let type = store.availableDependencyTypes.first else { return }
        dependencyType = type
    }

    private var controlColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 8, alignment: .leading)
        ]
    }
}

private struct DependencyRow: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issueID: String
    let dependency: BeadDependency

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.revealIssue(id: targetID)
            } label: {
                HStack(spacing: 8) {
                    Label(labelText, systemImage: systemImage)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let title = store.issue(with: targetID)?.title {
                        Text(title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Jump to \(targetID)")
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(dependency.type)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)

            Button {
                Task {
                    await store.removeDependency(dependency)
                }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove dependency")
        }
        .font(.callout)
        .padding(.vertical, 7)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var targetID: String {
        dependency.issueID == issueID ? dependency.dependsOnID : dependency.issueID
    }

    private var labelText: String {
        dependency.issueID == issueID
            ? "\(issueID) depends on \(dependency.dependsOnID)"
            : "\(dependency.issueID) depends on \(issueID)"
    }

    private var systemImage: String {
        dependency.issueID == issueID ? "arrow.down.right" : "arrow.up.forward"
    }
}
