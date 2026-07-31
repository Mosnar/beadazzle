import XCTest
@testable import Beadazzle

final class IssueTextSectionPreferencesTests: XCTestCase {
    func testBeadsDefaultsSuggestAcceptanceForBugFeatureAndTask() {
        let matrix = IssueTextSectionSuggestionMatrix.beadsDefault

        for type in ["bug", "feature", "task"] {
            XCTAssertEqual(matrix.sections(for: type), [.description, .acceptanceCriteria])
        }
        for type in ["epic", "chore", "decision", "custom-type"] {
            XCTAssertEqual(matrix.sections(for: type), [.description])
        }
    }

    func testPopulatedSectionsRemainVisibleOutsideSuggestions() {
        var draft = IssueDraft.blank(defaultType: "epic", defaultStatus: "open")
        draft.notes = "Useful context"

        let layout = IssueTextSectionPresentationPolicy.editorLayout(
            draft: draft,
            preferences: .beadsDefault,
            explicitlyRevealed: [],
            explicitlyHidden: []
        )

        XCTAssertEqual(layout.visible, [.description, .notes])
        XCTAssertEqual(layout.hidden, [.acceptanceCriteria, .design])
    }

    func testUntouchedDraftReplacesAutomaticSuggestionsWhenTypeChanges() {
        var draft = IssueDraft.blank(defaultType: "bug", defaultStatus: "open")

        XCTAssertEqual(
            IssueTextSectionPresentationPolicy.editorLayout(
                draft: draft,
                preferences: .beadsDefault,
                explicitlyRevealed: [],
                explicitlyHidden: []
            ).visible,
            [.description, .acceptanceCriteria]
        )

        draft.issueType = "epic"

        XCTAssertEqual(
            IssueTextSectionPresentationPolicy.editorLayout(
                draft: draft,
                preferences: .beadsDefault,
                explicitlyRevealed: [],
                explicitlyHidden: []
            ).visible,
            [.description]
        )

        draft.issueType = "feature"

        XCTAssertEqual(
            IssueTextSectionPresentationPolicy.editorLayout(
                draft: draft,
                preferences: .beadsDefault,
                explicitlyRevealed: [],
                explicitlyHidden: []
            ).visible,
            [.description, .acceptanceCriteria]
        )
    }

    func testExplicitlyRevealedSectionSurvivesTypeChange() {
        let draft = IssueDraft.blank(defaultType: "epic", defaultStatus: "open")

        XCTAssertEqual(
            IssueTextSectionPresentationPolicy.editorLayout(
                draft: draft,
                preferences: .beadsDefault,
                explicitlyRevealed: [.notes],
                explicitlyHidden: []
            ).visible,
            [.description, .notes]
        )
    }

    func testExplicitlyHiddenEmptySectionOverridesSuggestion() {
        let draft = IssueDraft.blank(defaultType: "bug", defaultStatus: "open")

        XCTAssertEqual(
            IssueTextSectionPresentationPolicy.editorLayout(
                draft: draft,
                preferences: .beadsDefault,
                explicitlyRevealed: [],
                explicitlyHidden: [.acceptanceCriteria]
            ).visible,
            [.description]
        )
        XCTAssertTrue(IssueTextSectionPresentationPolicy.canHide(.acceptanceCriteria, in: draft))
    }

    func testPopulatedSectionCannotBeHidden() {
        var draft = IssueDraft.blank(defaultType: "bug", defaultStatus: "open")
        draft.acceptanceCriteria = "Must remain visible"

        XCTAssertEqual(
            IssueTextSectionPresentationPolicy.editorLayout(
                draft: draft,
                preferences: .beadsDefault,
                explicitlyRevealed: [],
                explicitlyHidden: [.acceptanceCriteria]
            ).visible,
            [.description, .acceptanceCriteria]
        )
        XCTAssertFalse(IssueTextSectionPresentationPolicy.canHide(.acceptanceCriteria, in: draft))
    }

    func testContentDetectionIgnoresWhitespaceWithoutChangingDraftText() {
        var draft = IssueDraft.blank(defaultType: "task", defaultStatus: "open")
        draft.description = " \n\t "
        draft.notes = "  Useful context"

        XCTAssertFalse(IssueTextSection.description.hasContent(in: draft))
        XCTAssertTrue(IssueTextSection.notes.hasContent(in: draft))
        XCTAssertEqual(draft.description, " \n\t ")
    }

    func testClearingPopulatedSectionKeepsItExplicitlyRevealed() {
        XCTAssertTrue(IssueTextSectionPresentationPolicy.shouldRevealAfterEditing(
            existingText: "Existing notes",
            updatedText: "  \n"
        ))
        XCTAssertFalse(IssueTextSectionPresentationPolicy.shouldRevealAfterEditing(
            existingText: "",
            updatedText: ""
        ))
        XCTAssertFalse(IssueTextSectionPresentationPolicy.shouldRevealAfterEditing(
            existingText: "Existing notes",
            updatedText: "Replacement notes"
        ))
    }

    func testRevealingAndHidingAreReciprocalOverrides() {
        var overrides = IssueTextSectionVisibilityOverrides()

        overrides.hide(.design)
        XCTAssertEqual(overrides.hidden, [.design])
        XCTAssertTrue(overrides.revealed.isEmpty)

        overrides.reveal(.design)
        XCTAssertTrue(overrides.hidden.isEmpty)
        XCTAssertEqual(overrides.revealed, [.design])
    }

    func testProjectOverridesAreSparseAndInheritUnchangedAppRows() {
        var app = IssueTextSectionPreferences.beadsDefault
        app.order = [.notes, .description, .design, .acceptanceCriteria]
        let project = ProjectIssueTextSectionOverrides(
            visibilityMode: .allSections,
            order: nil,
            suggestionsByType: ["feature": [.description, .design]]
        )

        let effective = IssueTextSectionPresentationPolicy.effectivePreferences(
            app: app,
            project: project
        )

        XCTAssertEqual(effective.visibilityMode, .allSections)
        XCTAssertEqual(effective.order, app.order)
        XCTAssertEqual(effective.suggestions.sections(for: "feature"), [.description, .design])
        XCTAssertEqual(effective.suggestions.sections(for: "bug"), [.description, .acceptanceCriteria])
    }

    func testOrderNormalizationKeepsEverySectionExactlyOnce() {
        XCTAssertEqual(
            IssueTextSectionPreferences.normalizedOrder([.notes, .description, .notes]),
            [.notes, .description, .acceptanceCriteria, .design]
        )
    }

    func testHiddenSectionsFollowTheConfiguredOrder() {
        var preferences = IssueTextSectionPreferences.beadsDefault
        preferences.order = [.notes, .design, .description, .acceptanceCriteria]
        let draft = IssueDraft.blank(defaultType: "epic", defaultStatus: "open")

        let layout = IssueTextSectionPresentationPolicy.editorLayout(
            draft: draft,
            preferences: preferences,
            explicitlyRevealed: [],
            explicitlyHidden: []
        )

        XCTAssertEqual(layout.visible, [.description])
        XCTAssertEqual(layout.hidden, [.notes, .design, .acceptanceCriteria])
    }
}
