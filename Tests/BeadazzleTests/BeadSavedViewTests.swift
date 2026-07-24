import XCTest
@testable import Beadazzle

final class BeadSavedViewTests: XCTestCase {
    func testSavedViewRoundTripsAllFilterFields() throws {
        let view = BeadSavedView(
            id: UUID(),
            name: "Urgent Bugs",
            symbolName: "flame",
            query: BeadSavedViewQuery(
                basePreset: .open,
                statusFilters: ["open"],
                typeFilters: ["bug"],
                priorityFilters: [0, 1],
                labelFilters: ["urgent"],
                searchText: "crash"
            ),
            ordering: .sorted(BeadSavedViewSort(field: .updated, direction: .descending))
        )

        let decoded = try JSONDecoder().decode(BeadSavedView.self, from: JSONEncoder().encode(view))

        XCTAssertEqual(decoded, view)
    }

    func testBookmarkTokensRoundTripEveryPresetAndRejectUnknownValues() throws {
        for bookmark in BeadBookmark.allCases {
            XCTAssertEqual(BeadBookmarkToken(bookmark).bookmark, bookmark)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(BeadBookmarkToken.self, from: Data(#""future-preset""#.utf8))
        )
    }

    func testPredicateWireFormatIsTaggedAndUnknownNodeRejectsWholeGroup() throws {
        let first = BeadFilterCondition(field: .status, operation: .isAnyOf, value: BeadFilterValue(strings: ["open"]))
        let second = BeadFilterCondition(field: .labels, operation: .containsAny, value: BeadFilterValue(strings: ["urgent"]))
        let group = BeadFilterGroup(children: [.condition(first), .condition(second)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(group)) as? [String: Any])
        var children = try XCTUnwrap(object["children"] as? [[String: Any]])
        XCTAssertEqual(children[0]["kind"] as? String, "condition")
        children[0]["kind"] = "future-node"
        object["children"] = children

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BeadFilterGroup.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testConditionWireFormatUsesTypedValueEnvelope() throws {
        let condition = BeadFilterCondition(
            field: .status,
            operation: .isAnyOf,
            value: BeadFilterValue(text: "ignored", strings: ["open", "blocked"], number: 42)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(condition)) as? [String: Any]
        )
        let value = try XCTUnwrap(object["value"] as? [String: Any])

        XCTAssertEqual(value["kind"] as? String, "strings")
        XCTAssertEqual(Set(value["strings"] as? [String] ?? []), ["open", "blocked"])
        XCTAssertNil(value["text"])
        XCTAssertNil(value["number"])
        XCTAssertEqual(try JSONDecoder().decode(BeadFilterCondition.self, from: JSONEncoder().encode(condition)).value.strings, ["open", "blocked"])
    }

    func testDuplicatePredicateNodeIDsRejectSavedView() throws {
        let duplicateID = UUID()
        let first = BeadFilterCondition(id: duplicateID, field: .status, operation: .isAnyOf, value: BeadFilterValue(strings: ["open"]))
        let second = BeadFilterCondition(id: duplicateID, field: .type, operation: .isAnyOf, value: BeadFilterValue(strings: ["task"]))
        let filter = BeadSavedViewQuery(
            basePreset: .all,
            statusFilters: [], typeFilters: [], priorityFilters: [], labelFilters: [], searchText: "",
            advancedPredicate: BeadFilterGroup(children: [.condition(first), .condition(second)])
        )
        let encoded = try JSONEncoder().encode(BeadSavedView(
            id: UUID(), name: "Duplicate", symbolName: "bookmark", query: filter,
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        ))

        XCTAssertThrowsError(try JSONDecoder().decode(BeadSavedView.self, from: encoded))
    }

    func testVersionTwoPayloadRoundTripsSmartBookmarksAndFolders() throws {
        let smartView = makeSavedView(
            ordering: .sorted(BeadSavedViewSort(field: .updated, direction: .descending))
        )
        let folderView = BeadSavedView(
            id: UUID(),
            name: "Planning",
            symbolName: "folder",
            content: .folder(BeadFolderBookmark(orderedIssueIDs: ["bd-3", "bd-1"]))
        )
        let payload = BeadSavedViewsPayload(views: [smartView, folderView])
        let data = try JSONEncoder().encode(payload)

        let decoded = try JSONDecoder().decode(BeadSavedViewsPayload.self, from: data)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.views, payload.views)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["rootNodes"])
        let views = try XCTUnwrap(object["views"] as? [[String: Any]])
        let smartContent = try XCTUnwrap(views[0]["content"] as? [String: Any])
        let folderContent = try XCTUnwrap(views[1]["content"] as? [String: Any])
        XCTAssertEqual(smartContent["kind"] as? String, "smart")
        XCTAssertEqual(folderContent["kind"] as? String, "folder")
        XCTAssertNil(views[0]["query"])
        XCTAssertNil(views[0]["ordering"])
    }

    private func makeSavedView(
        ordering: BeadSavedViewOrdering = .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
    ) -> BeadSavedView {
        BeadSavedView(
            id: UUID(),
            name: "Focus",
            symbolName: "bookmark",
            query: BeadSavedViewQuery(
                basePreset: .all,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: ""
            ),
            ordering: ordering
        )
    }
}
