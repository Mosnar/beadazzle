import SwiftUI

struct SidebarView: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        List(selection: bookmarkSelection) {
            Section("Project") {
                ProjectPickerButton()
            }

            Section {
                ForEach(BeadBookmark.allCases) { bookmark in
                    BookmarkRow(bookmark: bookmark, count: store.count(for: bookmark))
                        .tag(bookmark)
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

    private var bookmarkSelection: Binding<BeadBookmark?> {
        Binding(
            get: { store.selectedBookmark },
            set: { bookmark in
                if let bookmark {
                    store.applyBookmark(bookmark)
                }
            }
        )
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
