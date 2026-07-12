import SwiftUI

struct SidebarView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var project: BeadProjectStore { store.project }
    private var workspace: BeadWorkspaceStore { store.workspace }
    let onSaveBookmark: () -> Void
    let onEditBookmark: (UUID) -> Void

    var body: some View {
        List(selection: bookmarkSelection) {
            Section("Project") {
                ProjectPickerButton()
                if project.snapshotFreshness.state == .possiblyStale {
                    SnapshotFreshnessSidebarRow(freshness: project.snapshotFreshness)
                }
            }

            Section {
                ForEach(BeadBookmark.allCases) { bookmark in
                    BookmarkRow(bookmark: bookmark, count: store.count(for: bookmark))
                        .tag(BeadSidebarSelection.preset(bookmark))
                }
            }

            Section {
                if let message = workspace.savedViewsPersistenceMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .accessibilityHint("The original bookmark data was preserved.")
                }
                if workspace.savedViews.isEmpty, workspace.savedViewsPersistenceMessage == nil {
                    Text("No bookmarks yet")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No saved bookmarks")
                } else if !workspace.savedViews.isEmpty {
                    ForEach(workspace.savedViews) { savedView in
                        SavedViewRow(
                            view: savedView,
                            count: store.count(forSavedViewID: savedView.id),
                            countIsLoading: workspace.isRebuildingSavedViewCounts,
                            onEdit: { onEditBookmark(savedView.id) }
                        )
                            .tag(BeadSidebarSelection.savedView(savedView.id))
                    }
                    .onMove(perform: store.moveSavedViews)
                }
            } header: {
                HStack {
                    Text("Bookmarks")
                    Spacer()
                    Button(action: onSaveBookmark) {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .disabled(!store.canCreateSavedView)
                    .help("Save Current View as Bookmark")
                    .accessibilityLabel("Save current view as bookmark")
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if project.isLoading {
                ProgressView()
            }
        }
    }

    private var bookmarkSelection: Binding<BeadSidebarSelection?> {
        Binding(
            get: {
                if let id = workspace.activeSavedViewID {
                    return .savedView(id)
                }
                return .preset(workspace.selectedBookmark)
            },
            set: { selection in
                guard let selection else { return }
                store.scheduleSidebarSelection(selection)
            }
        )
    }
}

private struct SnapshotFreshnessSidebarRow: View {
    let freshness: ProjectSnapshotFreshness

    var body: some View {
        Label {
            Text(freshness.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } icon: {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
        .help(freshness.detail ?? freshness.message)
    }
}

private struct BookmarkRow: View {
    let bookmark: BeadBookmark
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bookmark.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(bookmark.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(count.formatted())
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
