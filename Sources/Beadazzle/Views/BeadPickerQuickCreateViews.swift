import SwiftUI

struct BeadPickerQuickCreateTextField: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let focusedField: FocusState<BeadPickerQuickCreateField?>.Binding
    let focusID: BeadPickerQuickCreateField
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(focusedField, equals: focusID)
                .disabled(isDisabled)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(BeadPickerChrome.controlFill, in: RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous)
                .stroke(BeadPickerChrome.controlStroke, lineWidth: 1)
        }
    }
}

struct BeadPickerQuickCreateTypeMenu: View {
    @Binding var selectedType: String
    let typeOptions: [String]
    let isDisabled: Bool

    var body: some View {
        Menu {
            ForEach(typeOptions, id: \.self) { type in
                Button {
                    selectedType = type
                } label: {
                    if selectedType == type {
                        Label(type, systemImage: "checkmark")
                    } else {
                        Text(type)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "tag")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Text(selectedType.nilIfBlank ?? "Type")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BeadPickerChrome.controlFill, in: RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous)
                    .stroke(BeadPickerChrome.controlStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("Type")
        .accessibilityValue(selectedType)
    }
}

struct BeadPickerQuickCreateLabelsControl: View {
    @Binding var labels: [String]
    let availableLabels: [String]
    let isDisabled: Bool
    @State private var isPresented = false
    @State private var isHovered = false

    private var displayValue: String {
        guard !labels.isEmpty else { return "Labels" }
        if labels.count <= 2 {
            return labels.joined(separator: ", ")
        }
        return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2)"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "tag")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Text(displayValue)
                    .font(.callout)
                    .foregroundStyle(labels.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered || isPresented ? BeadPickerChrome.rowHoverFill : BeadPickerChrome.controlFill,
                in: RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous)
                    .stroke(BeadPickerChrome.controlStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: BeadPickerChrome.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help("Edit labels")
        .accessibilityLabel("Labels")
        .accessibilityValue(labels.isEmpty ? "None" : labels.joined(separator: ", "))
        .accessibilityHint("Opens the label editor")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            LabelEditorPopover(labels: $labels, availableLabels: availableLabels)
        }
    }
}

struct BeadPickerQuickCreatePriorityControl: View {
    @Binding var priority: Int

    var body: some View {
        Picker("Priority", selection: $priority) {
            ForEach(Array(0...4), id: \.self) { priority in
                Text("P\(priority)").tag(priority)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Priority")
    }
}
