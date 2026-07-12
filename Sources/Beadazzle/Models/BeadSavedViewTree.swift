import Foundation

struct BeadSavedViewFolder: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var children: [BeadSavedViewNode]
}

indirect enum BeadSavedViewNode: Identifiable, Hashable, Codable, Sendable {
    case folder(BeadSavedViewFolder)
    case view(BeadSavedView)

    var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .view(let view): view.id
        }
    }

    var savedViews: [BeadSavedView] {
        switch self {
        case .folder(let folder): folder.children.flatMap(\.savedViews)
        case .view(let view): [view]
        }
    }

    var outlineChildren: [BeadSavedViewNode]? {
        guard case .folder(let folder) = self else { return nil }
        return folder.children
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

struct BeadSavedViewTree: Equatable, Sendable {
    private(set) var rootNodes: [BeadSavedViewNode]
    private(set) var savedViews: [BeadSavedView]
    private var viewsByID: [UUID: BeadSavedView]

    init(rootNodes: [BeadSavedViewNode] = []) {
        self.rootNodes = rootNodes
        let views = rootNodes.flatMap(\.savedViews)
        savedViews = views
        viewsByID = Dictionary(views.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootNodes == rhs.rootNodes
    }

    var isEmpty: Bool { rootNodes.isEmpty }
    var containsFolders: Bool { rootNodes.contains { if case .folder = $0 { true } else { false } } }
    var hasUniqueNodeIDs: Bool { rootNodes.hasUniqueNodeIDs }

    func savedView(id: UUID) -> BeadSavedView? {
        viewsByID[id]
    }

    mutating func append(_ view: BeadSavedView) {
        rootNodes.append(.view(view))
        rebuildIndex()
    }

    @discardableResult
    mutating func updateSavedView(id: UUID, _ update: (inout BeadSavedView) -> Void) -> Bool {
        guard rootNodes.updateSavedView(id: id, update) else { return false }
        rebuildIndex()
        return true
    }

    @discardableResult
    mutating func removeSavedView(id: UUID) -> Bool {
        guard rootNodes.removeSavedView(id: id) else { return false }
        rebuildIndex()
        return true
    }

    @discardableResult
    mutating func insertSavedView(_ view: BeadSavedView, after id: UUID) -> Bool {
        guard rootNodes.insertSavedView(view, after: id) else { return false }
        rebuildIndex()
        return true
    }

    mutating func moveRootNodes(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.filter { rootNodes.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.map { rootNodes[$0] }
        for offset in validOffsets.reversed() {
            rootNodes.remove(at: offset)
        }
        let removedBeforeDestination = validOffsets.lazy.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), rootNodes.count)
        rootNodes.insert(contentsOf: moving, at: insertionIndex)
        rebuildIndex()
    }

    @discardableResult
    mutating func moveRootNodeUp(id: UUID) -> Bool {
        guard let index = rootNodes.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        rootNodes.swapAt(index, index - 1)
        rebuildIndex()
        return true
    }

    @discardableResult
    mutating func moveRootNodeDown(id: UUID) -> Bool {
        guard let index = rootNodes.firstIndex(where: { $0.id == id }),
              index < rootNodes.index(before: rootNodes.endIndex) else { return false }
        rootNodes.swapAt(index, index + 1)
        rebuildIndex()
        return true
    }

    func canMoveRootNodeUp(id: UUID) -> Bool {
        guard let index = rootNodes.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0
    }

    func canMoveRootNodeDown(id: UUID) -> Bool {
        guard let index = rootNodes.firstIndex(where: { $0.id == id }) else { return false }
        return index < rootNodes.index(before: rootNodes.endIndex)
    }

    mutating func normalize(
        view viewTransform: (BeadSavedView) -> BeadSavedView,
        folder folderTransform: (BeadSavedViewFolder) -> BeadSavedViewFolder
    ) {
        rootNodes = rootNodes.map {
            $0.normalized(view: viewTransform, folder: folderTransform)
        }
        rebuildIndex()
    }

    private mutating func rebuildIndex() {
        let views = rootNodes.flatMap(\.savedViews)
        savedViews = views
        viewsByID = Dictionary(views.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                      view.query.advancedPredicate?.hasUniqueNodeIDs != false,
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

private extension Array where Element == BeadSavedViewNode {
    func savedView(id: UUID) -> BeadSavedView? {
        for node in self {
            switch node {
            case .view(let view) where view.id == id:
                return view
            case .folder(let folder):
                if let view = folder.children.savedView(id: id) { return view }
            default:
                continue
            }
        }
        return nil
    }

    @discardableResult
    mutating func updateSavedView(id: UUID, _ update: (inout BeadSavedView) -> Void) -> Bool {
        for index in indices {
            switch self[index] {
            case .view(var view) where view.id == id:
                update(&view)
                self[index] = .view(view)
                return true
            case .folder(var folder):
                if folder.children.updateSavedView(id: id, update) {
                    self[index] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    @discardableResult
    mutating func removeSavedView(id: UUID) -> Bool {
        for index in indices {
            switch self[index] {
            case .view(let view) where view.id == id:
                remove(at: index)
                return true
            case .folder(var folder):
                if folder.children.removeSavedView(id: id) {
                    self[index] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    @discardableResult
    mutating func insertSavedView(_ newView: BeadSavedView, after id: UUID) -> Bool {
        for index in indices {
            switch self[index] {
            case .view(let view) where view.id == id:
                insert(.view(newView), at: index + 1)
                return true
            case .folder(var folder):
                if folder.children.insertSavedView(newView, after: id) {
                    self[index] = .folder(folder)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    var hasUniqueNodeIDs: Bool {
        var ids: Set<UUID> = []
        return collectUniqueNodeIDs(into: &ids)
    }

    private func collectUniqueNodeIDs(into ids: inout Set<UUID>) -> Bool {
        for node in self {
            guard ids.insert(node.id).inserted else { return false }
            if case .folder(let folder) = node,
               !folder.children.collectUniqueNodeIDs(into: &ids) {
                return false
            }
        }
        return true
    }
}
