import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let beadazzleBeadDrag = UTType(exportedAs: "app.beadazzle.bead-drag")
}

struct BeadDragPayload: Codable, Hashable, Sendable, Transferable {
    let projectIdentity: String
    let issueID: String
    let additionalIssueIDs: [String]
    let sourceFolderID: UUID?

    var issueIDs: [String] {
        [issueID] + additionalIssueIDs
    }

    init(projectIdentity: String, issueID: String, sourceFolderID: UUID?) {
        self.projectIdentity = projectIdentity
        self.issueID = issueID
        additionalIssueIDs = []
        self.sourceFolderID = sourceFolderID
    }

    init(projectIdentity: String, issueIDs: [String], sourceFolderID: UUID?) {
        precondition(!issueIDs.isEmpty)
        self.projectIdentity = projectIdentity
        issueID = issueIDs[0]
        additionalIssueIDs = Array(issueIDs.dropFirst())
        self.sourceFolderID = sourceFolderID
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .beadazzleBeadDrag)
    }
}
