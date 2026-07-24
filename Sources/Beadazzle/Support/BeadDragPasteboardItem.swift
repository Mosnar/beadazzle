import AppKit
import UniformTypeIdentifiers

enum BeadDragPasteboardItem {
    static func make(payload: BeadDragPayload) -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .beadazzleBeadDrag)
        item.setData(data, forType: .beadazzleBeadDragJSON)
        return item
    }
}

extension NSPasteboard.PasteboardType {
    static let beadazzleBeadDrag = Self(UTType.beadazzleBeadDrag.identifier)
    static let beadazzleBeadDragJSON = Self(UTType.json.identifier)
}
