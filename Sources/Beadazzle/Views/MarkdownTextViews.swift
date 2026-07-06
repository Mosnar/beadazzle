import AppKit
import MarkdownEngine
import SwiftUI

struct MarkdownFieldEditor: View {
    @Binding var text: String
    let placeholder: String
    let documentID: String
    let minimumLineCount: Int

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontSize: Self.bodyFontSize,
            documentId: documentID,
            placeholder: placeholderText
        )
        .frame(
            maxWidth: IssueDetailLayout.textColumnMaxWidth,
            minHeight: minimumHeight,
            alignment: .topLeading
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.heightBehavior = .fitsContent
        config.scrollers = .hidden
        config.textInsets = .init(horizontal: 0, vertical: 0)
        config.paragraph = .init(spacingFactor: 0.18, lineHeightExtraSpacing: 2)
        config.spellChecking = .init(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false
        )
        return config
    }

    private var placeholderText: NSAttributedString {
        NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.bodyFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
    }

    private var minimumHeight: CGFloat {
        CGFloat(minimumLineCount) * 22
    }

    private static var bodyFontSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize
    }
}
