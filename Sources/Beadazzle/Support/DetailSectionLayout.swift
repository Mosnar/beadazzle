/// Limits eager layout in the detail page. Small sections use PR #6's regular
/// stack workaround; large sections keep their existing lazy loading behavior.
enum DetailSectionLayout: Equatable {
    case eager
    case lazy

    private static let maximumEagerRows = 64
    // A few long comments still need the workaround. Only unusually large
    // text volumes fall back to lazy layout before reaching the row limit.
    private static let maximumEagerTextBytes = 256 * 1024

    /// Once a section grows large, do not recreate its rows again when a
    /// refresh removes items. A new issue starts with a new stack identity.
    func retainingLazyLayout(from previous: Self) -> Self {
        previous == .lazy ? .lazy : self
    }

    static func activity(_ items: [IssueActivityItem]) -> Self {
        guard items.count <= maximumEagerRows else { return .lazy }
        var remainingBytes = maximumEagerTextBytes
        for item in items {
            // Comments and event reasons can wrap to many lines. The other
            // metadata is line-limited, so the row limit bounds its work.
            let text: String
            switch item {
            case .comment(let comment): text = comment.text
            case .event(let event): text = event.reason ?? ""
            }
            let byteCount = text.utf8.count
            guard byteCount <= remainingBytes else { return .lazy }
            remainingBytes -= byteCount
        }
        return .eager
    }

    static func subIssues(count: Int) -> Self {
        count <= maximumEagerRows ? .eager : .lazy
    }
}
