import AppKit
import UniformTypeIdentifiers

enum BeadDragPasteboardItem {
    static func make(payload: BeadDragPayload) -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .beadazzleBeadDrag)
        return item
    }
}

extension NSPasteboard.PasteboardType {
    static let beadazzleBeadDrag = Self(UTType.beadazzleBeadDrag.identifier)
}
