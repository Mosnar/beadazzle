import XCTest
@testable import Beadazzle

@MainActor
final class BeadPickerModelTests: XCTestCase {
    func testApplySelectsFirstSelectableRowAndKeyboardMovesBetweenSelectableRows() {
        let model = BeadPickerModel()
        model.apply(BeadPickerQueryResult(
            rows: [
                pickerRow(id: "bd-context", title: "Context", isSelectable: false),
                pickerRow(id: "bd-a", title: "A", isSelectable: true),
                pickerRow(id: "bd-b", title: "B", isSelectable: true)
            ],
            matchingIssueIDs: ["bd-a", "bd-b"]
        ))

        XCTAssertEqual(model.selectedIssueID, "bd-a")
        XCTAssertEqual(model.selectableIssueIDs, ["bd-a", "bd-b"])
        XCTAssertFalse(model.isSelectable(issueID: "bd-context"))
        XCTAssertTrue(model.isSelectable(issueID: "bd-a"))
        model.moveSelectionDown()
        XCTAssertEqual(model.selectedIssueID, "bd-b")
        model.moveSelectionDown()
        XCTAssertEqual(model.selectedIssueID, "bd-b")
        model.moveSelectionUp()
        XCTAssertEqual(model.selectedIssueID, "bd-a")
    }

    func testToggleExpansionUpdatesOutlineState() {
        let model = BeadPickerModel()
        model.apply(BeadPickerQueryResult(
            rows: [
                pickerRow(id: "bd-parent", title: "Parent", hasChildren: true, isExpanded: false, isSelectable: true)
            ],
            matchingIssueIDs: ["bd-parent"]
        ))

        model.toggleExpansion(issueID: "bd-parent")

        XCTAssertTrue(model.outlineState.expandedIssueIDs.contains("bd-parent"))
    }

    func testQuickCreateTitleTracksSearchUntilEditedAndRequiresTitleAndType() {
        let model = BeadPickerModel()
        model.configure(
            configuration: .child(parent: issue(id: "bd-parent", title: "Parent")),
            defaultDraft: IssueDraft.blank(defaultType: "task", defaultStatus: "open", parentID: "bd-parent")
        )

        XCTAssertFalse(model.canCreateQuickBead)
        model.searchText = "New child"
        XCTAssertEqual(model.quickCreateTitle, "New child")
        XCTAssertTrue(model.canCreateQuickBead)

        model.setQuickCreateTitle("Custom child")
        model.searchText = "Ignored search"

        XCTAssertEqual(model.quickCreateTitle, "Custom child")
    }

    func testOnlyChildQuickCreateAlreadyHasItsRelationship() {
        XCTAssertFalse(BeadPickerAction.addChild(parentID: "bd-parent").needsPostCreateRelationship)
        XCTAssertTrue(BeadPickerAction.setParent(issueID: "bd-child").needsPostCreateRelationship)
        XCTAssertTrue(BeadPickerAction.addBlockedBy(issueID: "bd-child").needsPostCreateRelationship)
        XCTAssertTrue(BeadPickerAction.addBlocks(issueID: "bd-child").needsPostCreateRelationship)
    }

    private func pickerRow(
        id: String,
        title: String,
        hasChildren: Bool = false,
        isExpanded: Bool = false,
        isSelectable: Bool
    ) -> BeadPickerRow {
        BeadPickerRow(
            issue: issue(id: id, title: title),
            row: IssueListRow(
                issueID: id,
                depth: 0,
                hasChildren: hasChildren,
                childProgress: nil,
                isExpanded: isExpanded,
                isContext: !isSelectable
            ),
            isSelectable: isSelectable
        )
    }

    private func issue(id: String, title: String) -> BeadIssue {
        BeadIssue(
            id: id,
            title: title,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: "open",
            priority: 2,
            issueType: "task",
            assignee: nil,
            owner: nil,
            createdAt: nil,
            updatedAt: nil,
            closedAt: nil,
            dueAt: nil,
            deferUntil: nil,
            externalRef: nil,
            parentID: nil,
            labels: [],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }
}
