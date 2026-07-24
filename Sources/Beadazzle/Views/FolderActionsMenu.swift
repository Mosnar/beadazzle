import SwiftUI

struct FolderActionsMenu: View {
    @Environment(BeadStore.self) private var store
    let issueIDs: [String]

    var body: some View {
        AddToFolderMenu(issueIDs: issueIDs)

        if let folderID = store.activeFolderSavedView?.id {
            Button("Remove from Folder") {
                store.removeIssueIDs(Set(issueIDs), fromFolder: folderID)
            }
            .disabled(issueIDs.isEmpty || !store.canCreateSavedView)

            if store.canReorderActiveFolder {
                Menu("Move in Folder") {
                    Button("Move to Top") {
                        store.moveIssueIDs(issueIDs, inFolder: folderID, toOffset: 0)
                    }
                    Button("Move to Bottom") {
                        store.moveIssueIDs(
                            issueIDs,
                            inFolder: folderID,
                            toOffset: store.folderIssueIDs(
                                id: folderID,
                                resolvedOnly: false
                            ).count
                        )
                    }
                }
                .disabled(issueIDs.isEmpty || !store.canCreateSavedView)
            }
        }
    }
}

struct AddToFolderMenu: View {
    @Environment(BeadStore.self) private var store
    let issueIDs: [String]

    var body: some View {
        Menu("Add to Folder") {
            ForEach(store.folderSavedViews) { folder in
                Button(folder.name) {
                    store.addIssueIDs(issueIDs, toFolder: folder.id)
                }
            }
            if !store.folderSavedViews.isEmpty {
                Divider()
            }
            Button("New Folder from Selection…") {
                store.requestNewFolder(issueIDs: issueIDs)
            }
        }
        .disabled(issueIDs.isEmpty || !store.canCreateSavedView)
    }
}
