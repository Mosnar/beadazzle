import Foundation
import MarkdownEngine

struct IssueReferenceLookup: AutomaticLinkProvider, Sendable {
    static let empty = IssueReferenceLookup(issueIDs: [], revision: 0)

    let issueIDs: Set<String>
    let revision: Int
    let matcher: IssueReferenceMatcher

    init(issueIDs: Set<String>, revision: Int) {
        self.issueIDs = issueIDs
        self.revision = revision
        self.matcher = IssueReferenceMatcher(issueIDs: issueIDs)
    }

    func matches(in text: String, range: NSRange) -> [AutomaticLinkMatch] {
        matcher.matches(in: text, range: range).map { match in
            AutomaticLinkMatch(
                range: match.range,
                target: BeadIssueURL.string(for: match.issueID),
                activationPolicy: .commandClickWhenEditable
            )
        }
    }

    func fingerprint() -> AnyHashable { revision }
}

struct IssueReferenceMatch: Equatable, Sendable {
    let issueID: String
    let range: NSRange
}

/// Scans text for known issue IDs in O(text length), independent of how many
/// IDs the project has — the hot path allocates no per-token strings and
/// resolves candidates through hashed signatures plus a first-character mask.
///
/// ASCII-only by design: Beads issue IDs are `[A-Za-z0-9._-]`. An ID containing
/// any non-ASCII character can never be tokenized and will silently not link.
struct IssueReferenceMatcher: Sendable {
    private struct TokenSignature: Hashable, Sendable {
        let hash: UInt64
        let length: Int
    }

    private struct KnownIssueID: Sendable {
        let value: String
        let characters: [unichar]
    }

    let issueIDs: Set<String>
    private let minimumLength: Int
    private let maximumLength: Int
    private let acceptsSeparatorlessIDs: Bool
    private let knownIDsBySignature: [TokenSignature: [KnownIssueID]]
    private let firstCharacterMaskLow: UInt64
    private let firstCharacterMaskHigh: UInt64

    init(issueIDs: Set<String>) {
        self.issueIDs = issueIDs
        var minimumLength = Int.max
        var maximumLength = 0
        var acceptsSeparatorlessIDs = false
        var knownIDsBySignature: [TokenSignature: [KnownIssueID]] = [:]
        var firstCharacterMaskLow: UInt64 = 0
        var firstCharacterMaskHigh: UInt64 = 0
        for issueID in issueIDs {
            let characters = Array(issueID.utf16)
            let length = characters.count
            minimumLength = min(minimumLength, length)
            maximumLength = max(maximumLength, length)
            if !characters.contains(where: Self.isIssueIDSeparator) {
                acceptsSeparatorlessIDs = true
            }
            let signature = TokenSignature(hash: Self.hash(characters), length: length)
            knownIDsBySignature[signature, default: []].append(
                KnownIssueID(value: issueID, characters: characters)
            )
            if let first = characters.first {
                if first < 64 {
                    firstCharacterMaskLow |= UInt64(1) << UInt64(first)
                } else if first < 128 {
                    firstCharacterMaskHigh |= UInt64(1) << UInt64(first - 64)
                }
            }
        }
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.acceptsSeparatorlessIDs = acceptsSeparatorlessIDs
        self.knownIDsBySignature = knownIDsBySignature
        self.firstCharacterMaskLow = firstCharacterMaskLow
        self.firstCharacterMaskHigh = firstCharacterMaskHigh
    }

    func matches(in text: String, range requestedRange: NSRange? = nil) -> [IssueReferenceMatch] {
        let nsText = text as NSString
        let scanRange = requestedRange ?? NSRange(location: 0, length: nsText.length)
        guard !issueIDs.isEmpty,
              scanRange.location != NSNotFound,
              scanRange.location >= 0,
              scanRange.length > 0,
              NSMaxRange(scanRange) <= nsText.length else {
            return []
        }

        var characters = [unichar](repeating: 0, count: scanRange.length)
        nsText.getCharacters(&characters, range: scanRange)
        var matches: [IssueReferenceMatch] = []
        var cursor = 0
        let end = characters.count

        while cursor < end {
            guard Self.isIssueIDCharacter(characters[cursor]) else {
                cursor += 1
                continue
            }

            let tokenStart = cursor
            var containsSeparator = false
            repeat {
                let character = characters[cursor]
                containsSeparator = containsSeparator || Self.isIssueIDSeparator(character)
                cursor += 1
            } while cursor < end && Self.isIssueIDCharacter(characters[cursor])
            let tokenLength = cursor - tokenStart
            guard tokenLength >= minimumLength,
                  tokenLength <= maximumLength,
                  containsSeparator || acceptsSeparatorlessIDs,
                  isPossibleFirstCharacter(characters[tokenStart]) else {
                continue
            }
            var tokenHash = Self.hashOffsetBasis
            for index in tokenStart..<cursor {
                tokenHash = Self.hash(tokenHash, adding: characters[index])
            }
            let signature = TokenSignature(hash: tokenHash, length: tokenLength)
            guard let candidates = knownIDsBySignature[signature] else { continue }
            for candidate in candidates where Self.equals(
                candidate.characters,
                characters,
                startingAt: tokenStart
            ) {
                matches.append(IssueReferenceMatch(
                    issueID: candidate.value,
                    range: NSRange(
                        location: scanRange.location + tokenStart,
                        length: tokenLength
                    )
                ))
                break
            }
        }

        return matches
    }

    private static func isIssueIDCharacter(_ character: unichar) -> Bool {
        (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || (character >= 0x30 && character <= 0x39)
            || character == 0x2E
            || character == 0x5F
            || character == 0x2D
    }

    private static func isIssueIDSeparator(_ character: unichar) -> Bool {
        character == 0x2E || character == 0x5F || character == 0x2D
    }

    private func isPossibleFirstCharacter(_ character: unichar) -> Bool {
        if character < 64 {
            return firstCharacterMaskLow & (UInt64(1) << UInt64(character)) != 0
        }
        if character < 128 {
            return firstCharacterMaskHigh & (UInt64(1) << UInt64(character - 64)) != 0
        }
        return false
    }

    private static let hashOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let hashPrime: UInt64 = 1_099_511_628_211

    private static func hash(_ characters: [unichar]) -> UInt64 {
        characters.reduce(hashOffsetBasis) { hash($0, adding: $1) }
    }

    private static func hash(_ current: UInt64, adding character: unichar) -> UInt64 {
        (current ^ UInt64(character)) &* hashPrime
    }

    private static func equals(
        _ known: [unichar],
        _ text: [unichar],
        startingAt start: Int
    ) -> Bool {
        for index in known.indices where known[index] != text[start + index] {
            return false
        }
        return true
    }
}

enum BeadIssueURL {
    static func string(for issueID: String) -> String {
        var components = URLComponents()
        components.scheme = "beads"
        components.host = "bead"
        components.percentEncodedPath = "/" + encodedPathComponent(issueID)
        return components.string ?? "beads://bead/"
    }

    static func issueID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "beads",
              components.host == "bead",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.first == "/" else {
            return nil
        }

        let encodedID = components.percentEncodedPath.dropFirst()
        guard !encodedID.isEmpty,
              !encodedID.contains("/"),
              let issueID = String(encodedID).removingPercentEncoding,
              !issueID.isEmpty,
              !issueID.contains("/") else {
            return nil
        }
        return issueID
    }

    static func url(for issueID: String) -> URL? {
        URL(string: string(for: issueID))
    }

    private static func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

enum IssueReferenceAttributedStringBuilder {
    static func make(text: String, lookup: IssueReferenceLookup) -> AttributedString {
        var result = AttributedString(text)
        for match in lookup.matcher.matches(in: text) {
            guard let stringRange = Range(match.range, in: text),
                  let lowerBound = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upperBound = AttributedString.Index(stringRange.upperBound, within: result),
                  let url = BeadIssueURL.url(for: match.issueID) else {
                continue
            }
            result[lowerBound..<upperBound].link = url
        }
        return result
    }
}
