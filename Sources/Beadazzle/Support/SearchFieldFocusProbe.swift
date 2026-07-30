import AppKit
import OSLog

/// Answers "does the bead-list search field currently have keyboard focus?" so
/// ⌘F can escalate: first press focuses that field, a second press while it
/// still holds focus opens the in-bead find bar.
///
/// `.searchable` exposes only `isPresented`, and SwiftUI's `searchFocused`
/// modifier is macOS 15+ while this app targets macOS 14 — so the focus state
/// has to be read from AppKit. This is a single read inside a menu-command
/// handler, not an ongoing observation.
///
/// Apple documents that `.searchable` presents and focuses a search field on
/// macOS, but does **not** promise the backing view is an `NSSearchField`. The
/// match below therefore accepts a class-name match as well, which covers a
/// private SwiftUI type that isn't an `NSSearchField` subclass, and a miss is
/// logged with the responder's actual class so the real backing type can be
/// identified from one `build_and_run.sh --telemetry` run rather than guessed.
enum SearchFieldFocusProbe {
    private static let log = Logger(subsystem: "com.beadazzle.find", category: "SearchFieldFocus")

    @MainActor
    static var isSearchFieldFocused: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let matched = isSearchField(responder)
        if !matched, let responder {
            // Only interesting when something *is* focused and we didn't
            // recognize it — that's the case that would silently break ⌘F.
            log.debug("⌘F escalation declined: first responder is \(String(describing: type(of: responder)), privacy: .public)")
        }
        return matched
    }

    /// A focused search field makes the window's *field editor* the first
    /// responder, not the field itself. The editor's delegate is the field on the
    /// usual path; failing that, the field editor is installed inside the
    /// control, so the field is an ancestor view.
    ///
    /// Internal rather than private so tests can drive it with real focus
    /// instead of depending on `NSApp.keyWindow`.
    @MainActor
    static func isSearchField(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }

        if let textView = responder as? NSTextView, let delegate = textView.delegate {
            if delegate is NSSearchField || looksLikeSearchField(delegate) {
                return true
            }
        }

        guard let view = responder as? NSView else { return false }
        return view.enclosingSearchFieldLikeView != nil
    }

    /// Last-resort identification for a search control that isn't an
    /// `NSSearchField` subclass — SwiftUI is free to back `.searchable` with a
    /// private type, and a name check beats failing closed.
    static func looksLikeSearchField(_ object: Any) -> Bool {
        String(describing: type(of: object)).contains("SearchField")
    }
}

private extension NSView {
    var enclosingSearchFieldLikeView: NSView? {
        var candidate: NSView? = self
        while let view = candidate {
            if view is NSSearchField || SearchFieldFocusProbe.looksLikeSearchField(view) {
                return view
            }
            candidate = view.superview
        }
        return nil
    }
}
