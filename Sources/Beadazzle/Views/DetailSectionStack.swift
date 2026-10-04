import SwiftUI

/// Both layouts receive the full collection, in the same order. The budget
/// changes when rows are laid out, not which rows the user can reach.
struct DetailSectionStack<Content: View>: View {
    let layout: DetailSectionLayout
    @ViewBuilder let content: Content
    @State private var retainedLayout = DetailSectionLayout.eager

    var body: some View {
        Group {
            switch layout.retainingLazyLayout(from: retainedLayout) {
            case .eager:
                VStack(alignment: .leading, spacing: 0) { content }
            case .lazy:
                LazyVStack(alignment: .leading, spacing: 0) { content }
            }
        }
        .onChange(of: layout, initial: true) { _, nextLayout in
            retainedLayout = nextLayout.retainingLazyLayout(from: retainedLayout)
        }
    }
}
