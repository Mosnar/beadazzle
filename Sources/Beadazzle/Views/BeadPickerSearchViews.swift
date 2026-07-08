import AppKit
import SwiftUI

struct BeadPickerSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let wantsFocus: Bool
    let focus: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let submit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            BeadPickerSearchField(
                text: $text,
                placeholder: placeholder,
                wantsFocus: wantsFocus,
                focus: focus,
                moveUp: moveUp,
                moveDown: moveDown,
                submit: submit,
                dismiss: dismiss
            )
            .frame(height: 19)
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background(BeadPickerChrome.controlFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BeadPickerChrome.controlStroke, lineWidth: 1)
        }
    }
}

private struct BeadPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let wantsFocus: Bool
    let focus: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let submit: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> BeadPickerSearchNSTextField {
        let textField = BeadPickerSearchNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.cell?.isScrollable = true
        textField.cell?.usesSingleLineMode = true
        textField.onFocus = focus
        textField.wantsFocus = wantsFocus
        return textField
    }

    func updateNSView(_ nsView: BeadPickerSearchNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.onFocus = focus
        nsView.wantsFocus = wantsFocus
        nsView.focusIfNeeded()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BeadPickerSearchField

        init(_ parent: BeadPickerSearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focus()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.moveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.moveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.dismiss()
                return true
            default:
                return false
            }
        }
    }
}

private final class BeadPickerSearchNSTextField: NSTextField {
    var wantsFocus = false
    var onFocus: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocus()
        }
        return didBecomeFirstResponder
    }

    func focusIfNeeded() {
        guard wantsFocus, window != nil, currentEditor() == nil else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.wantsFocus, self.currentEditor() == nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}
