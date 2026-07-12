import SwiftUI

struct SidebarView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let onSaveBookmark: () -> Void
    let onEditBookmark: (UUID) -> Void

    var body: some View {
        List(selection: bookmarkSelection) {
            Section("Project") {
                ProjectPickerButton()
                if store.snapshotFreshness.state == .possiblyStale {
                    SnapshotFreshnessSidebarRow(freshness: store.snapshotFreshness)
                }
            }

            Section {
                ForEach(BeadBookmark.allCases) { bookmark in
                    BookmarkRow(bookmark: bookmark, count: store.count(for: bookmark))
                        .tag(BeadSidebarSelection.preset(bookmark))
                }
            }

            Section {
                if let message = store.savedViewsPersistenceMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .accessibilityHint("The original bookmark data was preserved.")
                }
                if store.savedViews.isEmpty, store.savedViewsPersistenceMessage == nil {
                    Text("No bookmarks yet")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No saved bookmarks")
                } else if !store.savedViews.isEmpty {
                    ForEach(store.savedViews) { savedView in
                        SavedViewRow(
                            view: savedView,
                            count: store.count(forSavedViewID: savedView.id),
                            countIsLoading: store.isRebuildingSavedViewCounts,
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
            if store.isLoading {
                ProgressView()
            }
        }
    }

    private var bookmarkSelection: Binding<BeadSidebarSelection?> {
        Binding(
            get: {
                if let id = store.activeSavedViewID {
                    return .savedView(id)
                }
                return .preset(store.selectedBookmark)
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
