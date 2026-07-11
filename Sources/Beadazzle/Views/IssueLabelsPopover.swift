import SwiftUI

struct IssueLabelsPopover: View {
    let labels: [String]

    var body: some View {
        HoverPersistentPopover(
            arrowEdge: .bottom,
            fillsAvailableWidth: false
        ) { _ in
            Label(labels.count.formatted(), systemImage: "tag")
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        } interactivePreview: {
            VStack(alignment: .leading, spacing: 10) {
                Label(summary, systemImage: "tag")
                    .font(.headline)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(labels, id: \.self) { label in
                            Label(label, systemImage: "tag.fill")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(summary)
        .accessibilityValue(labels.joined(separator: ", "))
        .accessibilityHint("Shows bead labels")
    }

    private var summary: String {
        labels.count == 1 ? "1 label" : "\(labels.count.formatted()) labels"
    }
}
