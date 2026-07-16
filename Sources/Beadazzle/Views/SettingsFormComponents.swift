import SwiftUI

struct SettingsDisclosure<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .accessibilityHidden(true)

                    Text(title)
                        .fontWeight(.medium)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides details" : "Shows details")

            if isExpanded {
                Divider()
                    .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, 20)
                .padding(.bottom, 4)
            }
        }
    }
}

struct SettingsDetailRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: () -> Value

    init(_ title: String, @ViewBuilder value: @escaping () -> Value) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            value()
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
