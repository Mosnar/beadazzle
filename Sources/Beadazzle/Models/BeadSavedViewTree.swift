import Foundation

/// Version 1 bookmark organization retained only for loss-tolerant migration.
/// Runtime bookmark and folder state is the flat version 2 `[BeadSavedView]` model.
struct BeadSavedViewFolder: Codable, Sendable {
    var id: UUID
    var name: String
    var children: [BeadSavedViewNode]
}

indirect enum BeadSavedViewNode: Codable, Sendable {
    case folder(BeadSavedViewFolder)
    case view(BeadSavedView)

    var savedViews: [BeadSavedView] {
        switch self {
        case .folder(let folder): folder.children.flatMap(\.savedViews)
        case .view(let view): [view]
        }
    }

    fileprivate enum CodingKeys: String, CodingKey { case kind, folder, view }
    fileprivate enum Kind: String, Codable { case folder, view }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .folder:
            self = .folder(try container.decode(BeadSavedViewFolder.self, forKey: .folder))
        case .view:
            self = .view(try container.decode(BeadSavedView.self, forKey: .view))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let folder):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(folder, forKey: .folder)
        case .view(let view):
            try container.encode(Kind.view, forKey: .kind)
            try container.encode(view, forKey: .view)
        }
    }
}

struct BeadSavedViewTree: Sendable {
    private(set) var rootNodes: [BeadSavedViewNode]
    private(set) var savedViews: [BeadSavedView]

    init(rootNodes: [BeadSavedViewNode] = []) {
        self.rootNodes = rootNodes
        savedViews = rootNodes.flatMap(\.savedViews)
    }

    mutating func normalize(
        view viewTransform: (BeadSavedView) -> BeadSavedView,
        folder folderTransform: (BeadSavedViewFolder) -> BeadSavedViewFolder
    ) {
        rootNodes = rootNodes.map {
            $0.normalized(view: viewTransform, folder: folderTransform)
        }
        savedViews = rootNodes.flatMap(\.savedViews)
    }
}

struct BeadSavedViewTreeRecoveryResult: Sendable {
    var tree: BeadSavedViewTree
    var recoveryIssueCount: Int
}

enum BeadSavedViewPersistenceState: Equatable, Sendable {
    enum ReadOnlyReason: Equatable, Sendable {
        case corrupt
        case unsupportedVersion
    }

    case ready
    case recovered(issueCount: Int, message: String)
    case readOnly(reason: ReadOnlyReason, message: String)

    var message: String? {
        switch self {
        case .ready: nil
        case .recovered(_, let message), .readOnly(_, let message): message
        }
    }

    var canMutate: Bool {
        if case .readOnly = self { return false }
        return true
    }

    var recoveryIssueCount: Int {
        switch self {
        case .recovered(let issueCount, _): issueCount
        case .readOnly(.corrupt, _): 1
        case .ready, .readOnly(.unsupportedVersion, _): 0
        }
    }

    var isCorrupt: Bool {
        guard case .readOnly(.corrupt, _) = self else { return false }
        return true
    }

    var hasUnsupportedVersion: Bool {
        guard case .readOnly(.unsupportedVersion, _) = self else { return false }
        return true
    }
}

extension BeadSavedViewTree {
    static func decodeRecovering(from data: Data) throws -> BeadSavedViewTreeRecoveryResult {
        let payload = try JSONDecoder().decode(RecoverablePayload.self, from: data)
        var seenNodeIDs: Set<UUID> = []
        let decoded = recoverNodes(payload.rootNodes, seenNodeIDs: &seenNodeIDs)
        return BeadSavedViewTreeRecoveryResult(
            tree: BeadSavedViewTree(rootNodes: decoded.nodes),
            recoveryIssueCount: decoded.recoveryIssueCount
        )
    }

    private static func recoverNodes(
        _ recoverableNodes: [Recoverable<RecoverableNode>],
        seenNodeIDs: inout Set<UUID>
    ) -> (nodes: [BeadSavedViewNode], recoveryIssueCount: Int) {
        var nodes: [BeadSavedViewNode] = []
        var recoveryIssueCount = 0

        for recoverableNode in recoverableNodes {
            guard let node = recoverableNode.value else {
                recoveryIssueCount += 1
                continue
            }
            switch node {
            case .view(let view):
                guard view.hasValidQuery,
                      view.smartQuery?.advancedPredicate?.hasUniqueNodeIDs != false,
                      seenNodeIDs.insert(view.id).inserted else {
                    recoveryIssueCount += 1
                    continue
                }
                nodes.append(.view(view))
            case .folder(let id, let name, let children):
                guard seenNodeIDs.insert(id).inserted else {
                    recoveryIssueCount += 1
                    continue
                }
                let decodedChildren = recoverNodes(children, seenNodeIDs: &seenNodeIDs)
                nodes.append(.folder(BeadSavedViewFolder(
                    id: id,
                    name: name,
                    children: decodedChildren.nodes
                )))
                recoveryIssueCount += decodedChildren.recoveryIssueCount
            }
        }
        return (nodes, recoveryIssueCount)
    }
}

private struct RecoverablePayload: Decodable {
    var rootNodes: [Recoverable<RecoverableNode>]
}

private struct Recoverable<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private indirect enum RecoverableNode: Decodable {
    case folder(id: UUID, name: String, children: [Recoverable<RecoverableNode>])
    case view(BeadSavedView)

    private enum FolderKeys: String, CodingKey { case id, name, children }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: BeadSavedViewNode.CodingKeys.self)
        switch try container.decode(BeadSavedViewNode.Kind.self, forKey: .kind) {
        case .folder:
            let folder = try container.nestedContainer(keyedBy: FolderKeys.self, forKey: .folder)
            self = .folder(
                id: try folder.decode(UUID.self, forKey: .id),
                name: try folder.decode(String.self, forKey: .name),
                children: try folder.decode([Recoverable<RecoverableNode>].self, forKey: .children)
            )
        case .view:
            self = .view(try container.decode(BeadSavedView.self, forKey: .view))
        }
    }
}

private extension BeadSavedViewNode {
    func normalized(
        view viewTransform: (BeadSavedView) -> BeadSavedView,
        folder folderTransform: (BeadSavedViewFolder) -> BeadSavedViewFolder
    ) -> Self {
        switch self {
        case .view(let view):
            return .view(viewTransform(view))
        case .folder(var folder):
            folder.children = folder.children.map {
                $0.normalized(view: viewTransform, folder: folderTransform)
            }
            return .folder(folderTransform(folder))
        }
    }
}
