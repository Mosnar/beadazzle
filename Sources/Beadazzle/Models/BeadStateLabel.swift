import Foundation

/// The `<dimension>:<value>` state-label convention used by `bd set-state`.
///
/// A state label is a fast lookup cache for an issue's current value along one
/// dimension (for example `phase:implementation`); the interactions log holds the
/// authoritative history. Each dimension holds at most one value per issue, so
/// applying a value replaces any existing label for that dimension.
enum BeadStateLabel {
    private static let eventTitlePrefix = "State change: "
    private static let eventTitleSeparator = " → "

    /// Splits a label into a state dimension and value on the first colon.
    /// This mirrors `bd state list`: any non-empty `dimension:value` label is a
    /// state-shaped label. Syntax alone does not prove that a label namespace was
    /// written by `bd set-state`; project discovery uses recorded event beads.
    static func parse(_ label: String) -> (dimension: String, value: String)? {
        guard let separator = label.firstIndex(of: ":") else { return nil }
        let dimension = String(label[..<separator])
        let value = String(label[label.index(after: separator)...])
        guard !dimension.isEmpty,
              !dimension.contains("="),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (dimension, value)
    }

    static func label(dimension: String, value: String) -> String {
        "\(dimension):\(value)"
    }

    /// A readable fallback for presentation surfaces. The underlying dimension
    /// remains unchanged because it is part of Beads' event-backed state key.
    static func displayName(for dimension: String) -> String {
        dimension
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    static func isDimensionName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(":") && !name.contains("=")
    }

    static func dimension(of label: String) -> String? {
        parse(label)?.dimension
    }

    static func value(of dimension: String, in labels: [String]) -> String? {
        for label in labels {
            if let parsed = parse(label), parsed.dimension == dimension {
                return parsed.value
            }
        }
        return nil
    }

    /// Removes any existing label for the dimension and appends the new one,
    /// mirroring what `bd set-state` does to the issue's labels.
    static func applying(dimension: String, value: String, to labels: [String]) -> [String] {
        labels.filter { parse($0)?.dimension != dimension } + [label(dimension: dimension, value: value)]
    }

    static func applying(overrides: [String: String], to labels: [String]) -> [String] {
        guard !overrides.isEmpty else { return labels }
        let dimensions = Set(overrides.keys)
        let ordinaryLabels = labels.filter { label in
            guard let dimensionName = dimension(of: label) else { return true }
            return !dimensions.contains(dimensionName)
        }
        let stateLabels = overrides.keys.sorted().compactMap { dimension in
            overrides[dimension].map { label(dimension: dimension, value: $0) }
        }
        return ordinaryLabels + stateLabels
    }

    static func excluding(dimensions: [String], from labels: [String]) -> [String] {
        guard !dimensions.isEmpty else { return labels }
        let dimensionSet = Set(dimensions)
        return labels.filter { label in
            guard let dimension = dimension(of: label) else { return true }
            return !dimensionSet.contains(dimension)
        }
    }

    /// Replaces ordinary labels while preserving the current labels for managed
    /// dimensions verbatim. The current issue, not an editor draft, owns those
    /// values so stale drafts cannot roll state backward.
    static func replacingOrdinaryLabels(
        in currentLabels: [String],
        with proposedLabels: [String],
        preserving dimensions: [String]
    ) -> [String] {
        guard !dimensions.isEmpty else { return proposedLabels }
        let dimensionSet = Set(dimensions)
        let ordinaryLabels = excluding(dimensions: dimensions, from: proposedLabels)
        let managedLabels = currentLabels.filter { label in
            guard let dimensionName = dimension(of: label) else { return false }
            return dimensionSet.contains(dimensionName)
        }
        return ordinaryLabels + managedLabels
    }

    static func normalizedDimensionInput(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDimensionName(normalized) else { return nil }
        return normalized
    }

    /// `bd set-state` splits on the first equals sign, so values may contain
    /// commas, equals signs, colons, and spaces. The app's label serialization is
    /// CSV-aware so those values remain lossless in drafts.
    static func normalizedValueInput(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    /// A cheap first-pass check used while indexing. Parsing is deferred until
    /// the project-wide label catalog is available so valid dimensions or
    /// values containing the event-title arrow can be disambiguated correctly.
    static func isRecordedChangeEvent(issueType: String, title: String) -> Bool {
        issueType == "event" && title.hasPrefix(eventTitlePrefix)
    }

    /// Most event titles contain exactly one separator and can be parsed while
    /// the issue index is already walking beads. Only the rare escaped shape
    /// needs the project label catalog built first.
    static func recordedChangeRequiresDisambiguation(title: String) -> Bool {
        guard title.hasPrefix(eventTitlePrefix) else { return false }
        let remainder = title.dropFirst(eventTitlePrefix.count)
        guard let firstSeparator = remainder.range(of: eventTitleSeparator) else {
            return false
        }
        return remainder.range(
            of: eventTitleSeparator,
            range: firstSeparator.upperBound..<remainder.endIndex
        ) != nil
    }

    /// Extracts explicit state provenance from the event bead created by
    /// `bd set-state`. This is intentionally stricter than `parse(_:)`: an
    /// arbitrary `area:ui` label is not offered as a state property merely
    /// because it contains a colon.
    ///
    /// `bd` permits the arrow token in both state names and values, even though
    /// it also uses that token as the event-title separator. Known labels and
    /// dimensions make the common ambiguous forms lossless; the first separator
    /// remains the compatibility fallback for historical events without either.
    static func recordedChange(
        issueType: String,
        title: String,
        knownLabels: Set<String> = [],
        knownDimensions: Set<String> = []
    ) -> (dimension: String, value: String)? {
        guard isRecordedChangeEvent(issueType: issueType, title: title) else {
            return nil
        }

        let remainder = title.dropFirst(eventTitlePrefix.count)
        guard let firstSeparator = remainder.range(of: eventTitleSeparator) else {
            return nil
        }
        let remainingRange = firstSeparator.upperBound..<remainder.endIndex
        guard remainder.range(of: eventTitleSeparator, range: remainingRange) != nil else {
            return recordedChangeCandidate(in: remainder, separator: firstSeparator)
        }

        var candidates: [(dimension: String, value: String)] = []
        if let firstCandidate = recordedChangeCandidate(in: remainder, separator: firstSeparator) {
            candidates.append(firstCandidate)
        }
        var searchStart = firstSeparator.upperBound
        while searchStart < remainder.endIndex,
              let separator = remainder.range(
                of: eventTitleSeparator,
                range: searchStart..<remainder.endIndex
              ) {
            if let candidate = recordedChangeCandidate(in: remainder, separator: separator) {
                candidates.append(candidate)
            }
            searchStart = separator.upperBound
        }
        guard !candidates.isEmpty else { return nil }

        var exactLabelMatch: (dimension: String, value: String)?
        var exactLabelMatchCount = 0
        for candidate in candidates where knownLabels.contains(
            label(dimension: candidate.dimension, value: candidate.value)
        ) {
            exactLabelMatch = candidate
            exactLabelMatchCount += 1
        }
        if exactLabelMatchCount == 1 {
            return exactLabelMatch
        }

        var dimensionMatch: (dimension: String, value: String)?
        var dimensionMatchCount = 0
        for candidate in candidates where knownDimensions.contains(candidate.dimension) {
            dimensionMatch = candidate
            dimensionMatchCount += 1
        }
        if dimensionMatchCount == 1 {
            return dimensionMatch
        }

        return candidates[0]
    }

    private static func recordedChangeCandidate(
        in remainder: Substring,
        separator: Range<String.Index>
    ) -> (dimension: String, value: String)? {
        let rawDimension = String(remainder[..<separator.lowerBound])
        let rawValue = String(remainder[separator.upperBound...])
        guard normalizedDimensionInput(rawDimension) == rawDimension,
              let value = normalizedValueInput(rawValue) else {
            return nil
        }
        return (rawDimension, value)
    }

    /// Localized natural order with a raw-string tie-breaker. Foundation can
    /// compare case variants as equal, which is not a stable order for the
    /// case-sensitive identifiers that `bd set-state` preserves.
    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        if comparison == .orderedSame {
            return lhs < rhs
        }
        return comparison == .orderedAscending
    }

    static let dimensionInputRequirement = "State names cannot be empty or contain colons or equals signs. Capitalization is preserved."
    static let valueInputRequirement = "State values cannot be empty."
}
