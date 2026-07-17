import XCTest
@testable import Beadazzle

final class BeadStateLabelTests: XCTestCase {
    func testDisplayNameFormatsIdentifierForPresentation() {
        XCTAssertEqual(BeadStateLabel.displayName(for: "release_phase"), "Release Phase")
        XCTAssertEqual(BeadStateLabel.displayName(for: "release-track"), "Release Track")
        XCTAssertEqual(BeadStateLabel.displayName(for: "Phase"), "Phase")
    }

    func testParseSplitsOnFirstColon() throws {
        let parsed = try XCTUnwrap(BeadStateLabel.parse("phase:implementation"))
        XCTAssertEqual(parsed.dimension, "phase")
        XCTAssertEqual(parsed.value, "implementation")

        let nested = try XCTUnwrap(BeadStateLabel.parse("a_b-1:x:y"))
        XCTAssertEqual(nested.dimension, "a_b-1")
        XCTAssertEqual(nested.value, "x:y")
    }

    func testParseRejectsOrdinaryLabels() {
        XCTAssertNil(BeadStateLabel.parse("plain-label"))
        XCTAssertNil(BeadStateLabel.parse(":value"))
        XCTAssertNil(BeadStateLabel.parse("phase:"))
        XCTAssertNil(BeadStateLabel.parse("phase:   "))
        XCTAssertNil(BeadStateLabel.parse("has=equals:value"))

        XCTAssertEqual(BeadStateLabel.parse("has space:value")?.dimension, "has space")
        XCTAssertEqual(BeadStateLabel.parse("punct.name:value")?.dimension, "punct.name")
    }

    func testValueOfDimensionReadsFirstMatch() {
        let labels = ["keeper", "phase:design", "health:ok"]
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: labels), "design")
        XCTAssertEqual(BeadStateLabel.value(of: "health", in: labels), "ok")
        XCTAssertNil(BeadStateLabel.value(of: "mode", in: labels))
    }

    func testApplyingReplacesDimensionLabelAndPreservesOthers() {
        let labels = ["keeper", "phase:design", "health:ok"]
        let updated = BeadStateLabel.applying(dimension: "phase", value: "implementation", to: labels)
        XCTAssertEqual(updated, ["keeper", "health:ok", "phase:implementation"])

        let added = BeadStateLabel.applying(dimension: "mode", value: "normal", to: labels)
        XCTAssertEqual(added, ["keeper", "phase:design", "health:ok", "mode:normal"])

        let overlaid = BeadStateLabel.applying(
            overrides: ["phase": "implementation", "health": "warning"],
            to: labels
        )
        XCTAssertEqual(overlaid, ["keeper", "health:warning", "phase:implementation"])
    }

    func testNormalizedDimensionInputPreservesCaseAndMatchesCLISeparators() {
        XCTAssertEqual(BeadStateLabel.normalizedDimensionInput("  Phase "), "Phase")
        XCTAssertEqual(BeadStateLabel.normalizedDimensionInput("a_b-1"), "a_b-1")
        XCTAssertEqual(BeadStateLabel.normalizedDimensionInput("bad name"), "bad name")
        XCTAssertEqual(BeadStateLabel.normalizedDimensionInput("punct.name"), "punct.name")
        XCTAssertEqual(BeadStateLabel.normalizedDimensionInput("-leading"), "-leading")
        XCTAssertNil(BeadStateLabel.normalizedDimensionInput(""))
        XCTAssertNil(BeadStateLabel.normalizedDimensionInput("has:colon"))
        XCTAssertNil(BeadStateLabel.normalizedDimensionInput("has=equals"))
    }

    func testNormalizedValueInputTrimsAndPreservesValidCLISeparators() {
        XCTAssertEqual(BeadStateLabel.normalizedValueInput("  in review "), "in review")
        XCTAssertEqual(BeadStateLabel.normalizedValueInput("a,b"), "a,b")
        XCTAssertEqual(BeadStateLabel.normalizedValueInput("a=b"), "a=b")
        XCTAssertNil(BeadStateLabel.normalizedValueInput(""))
        XCTAssertNil(BeadStateLabel.normalizedValueInput("   "))
    }

    func testRecordedChangeRequiresASetStateEventBead() {
        XCTAssertNil(BeadStateLabel.recordedChange(issueType: "task", title: "State change: phase → design"))
        XCTAssertNil(BeadStateLabel.recordedChange(issueType: "event", title: "Unrelated event"))

        let change = BeadStateLabel.recordedChange(
            issueType: "event",
            title: "State change: Phase → in,review=ready"
        )
        XCTAssertEqual(change?.dimension, "Phase")
        XCTAssertEqual(change?.value, "in,review=ready")
    }

    func testRecordedChangeUsesKnownLabelToDisambiguateArrowInDimension() {
        let change = BeadStateLabel.recordedChange(
            issueType: "event",
            title: "State change: release → phase → ready",
            knownLabels: ["release → phase:ready"],
            knownDimensions: ["release", "release → phase"]
        )

        XCTAssertEqual(change?.dimension, "release → phase")
        XCTAssertEqual(change?.value, "ready")
    }

    func testRecordedChangeUsesKnownLabelToDisambiguateArrowInValue() {
        let change = BeadStateLabel.recordedChange(
            issueType: "event",
            title: "State change: phase → ready → deploy",
            knownLabels: ["phase:ready → deploy"],
            knownDimensions: ["phase", "phase → ready"]
        )

        XCTAssertEqual(change?.dimension, "phase")
        XCTAssertEqual(change?.value, "ready → deploy")
    }

    func testStateIdentifierOrderingIsIndependentOfInputOrder() {
        let values = ["ready", "Ready", "READY", "ready2", "ready10"]

        XCTAssertEqual(
            values.sorted(by: BeadStateLabel.isOrderedBefore),
            values.reversed().sorted(by: BeadStateLabel.isOrderedBefore)
        )
    }

    func testValuePickerPolicyPreservesExactCaseSensitiveRawValue() {
        let values = [
            BeadStateValuePresentation(value: "Ready", displayName: "Ready", isArchived: false),
            BeadStateValuePresentation(value: "ready", displayName: "Ready (lowercase)", isArchived: false)
        ]

        XCTAssertEqual(
            BeadStateValuePickerPolicy.match(query: "ready", in: values),
            .unique(values[1])
        )
        XCTAssertEqual(
            BeadStateValuePickerPolicy.match(query: "READY", in: values),
            .ambiguous
        )
        XCTAssertEqual(
            BeadStateValuePickerPolicy.match(
                query: "ready",
                in: [values[0]],
                followedBy: [values[1]]
            ),
            .unique(values[1])
        )
        XCTAssertEqual(
            BeadStateValuePickerPolicy.match(
                query: "READY",
                in: [values[0]],
                followedBy: [values[1]]
            ),
            .ambiguous
        )
    }

    func testValuePickerPolicyPrefersRawIdentifiersAndRejectsDisplayNameAmbiguity() {
        let rawMatch = BeadStateValuePresentation(
            value: "ready",
            displayName: "Prepared",
            isArchived: false
        )
        let displayMatch = BeadStateValuePresentation(
            value: "prepared",
            displayName: "ready",
            isArchived: false
        )
        XCTAssertEqual(
            BeadStateValuePickerPolicy.match(query: "ready", in: [displayMatch, rawMatch]),
            .unique(rawMatch)
        )

        let duplicateDisplayName = BeadStateValuePresentation(
            value: "queued",
            displayName: "Prepared",
            isArchived: false
        )
        XCTAssertEqual(
            BeadStateValuePickerPolicy.match(
                query: "Prepared",
                in: [rawMatch, duplicateDisplayName]
            ),
            .ambiguous
        )
    }
}
