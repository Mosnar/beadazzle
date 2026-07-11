import Foundation

extension String {
    /// Finder-like ordering (case-insensitive, numeric-aware) without paying for an
    /// ICU collation per call. Sort comparators run O(n log n) times per query
    /// recompute — which fires on every keystroke — and `localizedStandardCompare`
    /// dominated that cost at thousands of issues.
    func naturalCompare(_ other: String) -> ComparisonResult {
        var lhs = unicodeScalars[...]
        var rhs = other.unicodeScalars[...]

        while let a = lhs.first, let b = rhs.first {
            if a.isASCIIDigit && b.isASCIIDigit {
                let comparison = Self.compareDigitRuns(&lhs, &rhs)
                if comparison != .orderedSame { return comparison }
            } else {
                let af = a.foldedForNaturalCompare
                let bf = b.foldedForNaturalCompare
                if af != bf { return af < bf ? .orderedAscending : .orderedDescending }
                lhs = lhs.dropFirst()
                rhs = rhs.dropFirst()
            }
        }
        if !lhs.isEmpty { return .orderedDescending }
        if !rhs.isEmpty { return .orderedAscending }
        return .orderedSame
    }

    /// Consumes the leading ASCII digit run from both sides and compares them as
    /// numbers: fewer significant digits sorts first, equal lengths compare
    /// lexicographically, ties fall through to the following text.
    private static func compareDigitRuns(
        _ lhs: inout Substring.UnicodeScalarView.SubSequence,
        _ rhs: inout Substring.UnicodeScalarView.SubSequence
    ) -> ComparisonResult {
        let aRun = lhs.prefix(while: \.isASCIIDigit)
        let bRun = rhs.prefix(while: \.isASCIIDigit)
        lhs = lhs.dropFirst(aRun.count)
        rhs = rhs.dropFirst(bRun.count)

        let aDigits = aRun.drop(while: { $0 == "0" })
        let bDigits = bRun.drop(while: { $0 == "0" })
        if aDigits.count != bDigits.count {
            return aDigits.count < bDigits.count ? .orderedAscending : .orderedDescending
        }
        for (a, b) in zip(aDigits, bDigits) where a != b {
            return a.value < b.value ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}

private extension Unicode.Scalar {
    var isASCIIDigit: Bool {
        (48...57).contains(value)
    }

    /// Case fold for ordering: cheap arithmetic for ASCII; a property lookup only for
    /// the rare non-ASCII scalar.
    var foldedForNaturalCompare: UInt32 {
        if value < 128 {
            return (65...90).contains(value) ? value + 32 : value
        }
        return properties.lowercaseMapping.unicodeScalars.first?.value ?? value
    }
}
