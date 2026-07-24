import Foundation
import UniformTypeIdentifiers

@MainActor
enum BeadFolderDropHandler {
    static let contentTypes: [UTType] = [.beadazzleBeadDrag]

    static func accept(
        _ providers: [NSItemProvider],
        into folderID: UUID,
        store: BeadStore
    ) -> Bool {
        guard !providers.isEmpty,
              providers.allSatisfy({
                  $0.hasItemConformingToTypeIdentifier(UTType.beadazzleBeadDrag.identifier)
              })
        else { return false }

        let collector = BeadFolderDropPayloadCollector(count: providers.count) { payloads in
            guard let payloads else {
                store.lastError = "The dragged beads could not be read."
                return
            }
            guard store.canAcceptBeadDragPayloads(payloads) else {
                store.lastError = "Beads can only be added to folders in the same project."
                return
            }
            _ = store.addBeadDragPayloads(payloads, toFolder: folderID)
        }

        for (index, provider) in providers.enumerated() {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.beadazzleBeadDrag.identifier
            ) { data, _ in
                let payload = data.flatMap {
                    try? JSONDecoder().decode(BeadDragPayload.self, from: $0)
                }
                Task { @MainActor in
                    collector.receive(payload, at: index)
                }
            }
        }
        return true
    }
}

@MainActor
final class BeadFolderDropPayloadCollector {
    private var payloads: [BeadDragPayload?]
    private var receivedIndices: Set<Int> = []
    private let completion: ([BeadDragPayload]?) -> Void

    init(
        count: Int,
        completion: @escaping ([BeadDragPayload]?) -> Void
    ) {
        payloads = Array(repeating: nil, count: count)
        self.completion = completion
    }

    func receive(_ payload: BeadDragPayload?, at index: Int) {
        guard payloads.indices.contains(index), receivedIndices.insert(index).inserted else {
            return
        }
        payloads[index] = payload
        guard receivedIndices.count == payloads.count else { return }
        guard payloads.allSatisfy({ $0 != nil }) else {
            completion(nil)
            return
        }
        completion(payloads.compactMap(\.self))
    }
}
