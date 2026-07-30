import MarkdownEngine
import SwiftUI

enum AboutDisclosure: String, CaseIterable, Identifiable {
    case acknowledgments
    case license

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acknowledgments:
            "Acknowledgments"
        case .license:
            "License"
        }
    }

    var windowID: String {
        "about-\(rawValue)"
    }

    var resourceName: String {
        switch self {
        case .acknowledgments:
            "THIRD_PARTY_NOTICES"
        case .license:
            "LICENSE"
        }
    }

    var resourceExtension: String? {
        switch self {
        case .acknowledgments:
            "md"
        case .license:
            nil
        }
    }
}

struct AboutDisclosureView: View {
    let document: AboutDisclosureDocument

    init(
        disclosure: AboutDisclosure,
        bundle: Bundle = .main
    ) {
        document = AboutDisclosureDocument(disclosure: disclosure, bundle: bundle)
    }

    var body: some View {
        switch document.contents {
        case let .loaded(contents):
            NativeTextViewWrapper(
                text: .constant(contents),
                configuration: Self.markdownConfiguration,
                fontSize: 14,
                documentId: "beadazzle-\(document.disclosure.rawValue)",
                isEditable: false
            )
        case let .unavailable(message):
            ContentUnavailableView(
                "Document Unavailable",
                systemImage: "doc.questionmark",
                description: Text(message)
            )
        }
    }

    private static var markdownConfiguration: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 760
        configuration.textInsets = .init(horizontal: 20, vertical: 18)
        configuration.spellChecking = .init(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false
        )
        return configuration
    }
}

struct AboutDisclosureDocument: Equatable {
    enum Contents: Equatable {
        case loaded(String)
        case unavailable(String)
    }

    let disclosure: AboutDisclosure
    let contents: Contents

    init(disclosure: AboutDisclosure, bundle: Bundle = .main) {
        let resourceURL = Self.resourceURL(for: disclosure, in: bundle)
        self.init(disclosure: disclosure, resourceURL: resourceURL)
    }

    init(disclosure: AboutDisclosure, resourceURL: URL?) {
        self.disclosure = disclosure

        guard let resourceURL else {
            contents = .unavailable(
                "\(disclosure.title) could not be found in this copy of Beadazzle."
            )
            return
        }

        do {
            contents = .loaded(try String(contentsOf: resourceURL, encoding: .utf8))
        } catch {
            contents = .unavailable(
                "\(disclosure.title) could not be read from this copy of Beadazzle."
            )
        }
    }

    private static func resourceURL(
        for disclosure: AboutDisclosure,
        in bundle: Bundle
    ) -> URL? {
        if let resourceURL = bundle.url(
            forResource: disclosure.resourceName,
            withExtension: disclosure.resourceExtension
        ) {
            return resourceURL
        }

        return Bundle.module.url(
            forResource: disclosure.resourceName,
            withExtension: disclosure.resourceExtension
        )
    }
}
