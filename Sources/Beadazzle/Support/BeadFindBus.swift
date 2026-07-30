import CoreGraphics
import Foundation
import MarkdownEngine

/// The notification contract between Beadazzle and the markdown engine's
/// find-in-document support.
///
/// The engine registers its bus observers with `object: nil`, so the *name* is
/// the only scope there is — which is why these are per-instance rather than
/// static. One window's `findQuery` must reach that window's four body fields
/// and no others: with shared names, two windows searching different terms
/// would overwrite each other's highlights, cross-file each other's counts, and
/// clear each other on Done. Each `BeadFindSession` owns one of these.
///
/// Within a window the four fields do share the names, which is exactly what
/// "highlight every match" needs. `focusDocumentId` then picks the single field
/// that owns the focused match — the others highlight without a focused match
/// and don't scroll.
struct BeadFindBus {
    let query: Notification.Name
    let results: Notification.Name
    let clearHighlights: Notification.Name

    init(id: UUID = UUID()) {
        let scope = id.uuidString
        query = Notification.Name("beadazzle.find.query.\(scope)")
        results = Notification.Name("beadazzle.find.results.\(scope)")
        clearHighlights = Notification.Name("beadazzle.find.clearHighlights.\(scope)")
    }

    enum Key {
        /// Host → engine, and echoed back so the host can drop replies for a
        /// query the user has already moved on from.
        static let query = "query"
        /// Host → engine: index of the focused match within `focusDocumentID`.
        static let currentIndex = "currentIndex"
        /// Host → engine: which document owns the focused match.
        static let focusDocumentID = "focusDocumentId"
        /// Round-trip identifier, echoed back so a reply from an earlier round of
        /// gathering can be told apart from one for the current round.
        static let requestToken = "requestToken"
        /// Engine → host: which document this reply is about.
        static let documentID = "documentId"
        /// Engine → host: how many matches this document holds.
        static let count = "count"
        /// Engine → host: the focused match's rect in the field's own
        /// top-leading coordinate space. Only the focused document sends one.
        static let matchRect = "matchRect"
    }

    /// The bus names to install on every body field's editor configuration.
    var editorBus: MarkdownEditorBus {
        MarkdownEditorBus(
            findClearHighlights: clearHighlights,
            findQuery: query,
            findResults: results
        )
    }

    /// Parse one engine reply and fold it into `session`.
    @MainActor
    static func ingest(_ notification: Notification, into session: BeadFindSession) {
        guard let info = notification.userInfo,
              let documentID = info[Key.documentID] as? String,
              let matchedQuery = info[Key.query] as? String,
              let count = info[Key.count] as? Int else { return }

        session.ingest(
            documentID: documentID,
            matchedQuery: matchedQuery,
            count: count,
            matchRect: info[Key.matchRect] as? CGRect,
            token: info[Key.requestToken] as? Int
        )
    }
}

/// Identity of the invisible view parked on the focused match. Exactly one field
/// carries it at a time, so `ScrollViewReader` can resolve it unambiguously.
enum BeadFindScrollAnchor {
    static let id = "beadazzle.find.currentMatch"
}

/// Posts find requests onto one session's bus.
@MainActor
final class BeadFindNotificationDispatcher: BeadFindDispatching {
    private let bus: BeadFindBus

    init(bus: BeadFindBus) {
        self.bus = bus
    }

    func send(_ request: BeadFindRequest) {
        var info: [AnyHashable: Any] = [
            BeadFindBus.Key.query: request.text,
            BeadFindBus.Key.currentIndex: request.focusIndex,
            BeadFindBus.Key.requestToken: request.token
        ]
        if let focusDocumentID = request.focusDocumentID {
            info[BeadFindBus.Key.focusDocumentID] = focusDocumentID
        }
        NotificationCenter.default.post(name: bus.query, object: nil, userInfo: info)
    }

    func clearHighlights() {
        NotificationCenter.default.post(name: bus.clearHighlights, object: nil)
    }
}
