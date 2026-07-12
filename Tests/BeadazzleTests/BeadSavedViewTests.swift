import XCTest
@testable import Beadazzle

final class BeadSavedViewTests: XCTestCase {
    func testFolderOnlyTreeIsNotEmpty() {
        let tree = BeadSavedViewTree(rootNodes: [
            .folder(BeadSavedViewFolder(id: UUID(), name: "Empty Folder", children: []))
        ])

        XCTAssertFalse(tree.isEmpty)
        XCTAssertTrue(tree.savedViews.isEmpty)
        XCTAssertTrue(tree.containsFolders)
    }

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

    func testFinalVersionOnePayloadRoundTripsFoldersQueriesAndManualOrdering() throws {
        let view = makeSavedView(
            ordering: .manual(BeadSavedViewManualOrdering(
                issueIDs: ["bd-3", "bd-1"],
                fallback: BeadSavedViewSort(field: .updated, direction: .descending)
            ))
        )
        let folder = BeadSavedViewFolder(id: UUID(), name: "Planning", children: [.view(view)])
        let payload = BeadSavedViewsPayload(rootNodes: [.folder(folder)])
        let data = try JSONEncoder().encode(payload)

        let decoded = try JSONDecoder().decode(BeadSavedViewsPayload.self, from: data)
        XCTAssertEqual(decoded.rootNodes, payload.rootNodes)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["rootNodes"])
        XCTAssertNil(object["views"])
        let rootNodes = try XCTUnwrap(object["rootNodes"] as? [[String: Any]])
        let folderObject = try XCTUnwrap(rootNodes.first?["folder"] as? [String: Any])
        let children = try XCTUnwrap(folderObject["children"] as? [[String: Any]])
        let viewObject = try XCTUnwrap(children.first?["view"] as? [String: Any])
        XCTAssertNotNil(viewObject["query"])
        XCTAssertNotNil(viewObject["ordering"])
        XCTAssertNil((viewObject["query"] as? [String: Any])?["sort"])
    }

    func testTreeHelpersPreserveFolderPlacementForBookmarkMutations() throws {
        let original = makeSavedView()
        var tree = BeadSavedViewTree(rootNodes: [
            .folder(BeadSavedViewFolder(id: UUID(), name: "Planning", children: [.view(original)]))
        ])
        let duplicate = makeSavedView()

        XCTAssertTrue(tree.updateSavedView(id: original.id) { $0.name = "Renamed" })
        XCTAssertTrue(tree.insertSavedView(duplicate, after: original.id))
        XCTAssertEqual(tree.savedViews.map(\.name), ["Renamed", duplicate.name])
        XCTAssertTrue(tree.removeSavedView(id: original.id))
        XCTAssertEqual(tree.savedViews, [duplicate])
        guard case .folder(let folder) = tree.rootNodes.first else { return XCTFail("Expected folder") }
        XCTAssertEqual(folder.children, [.view(duplicate)])
    }

    func testTreeRejectsDuplicateFolderAndBookmarkIdentities() {
        let view = makeSavedView()
        let tree = BeadSavedViewTree(rootNodes: [
            .folder(BeadSavedViewFolder(id: view.id, name: "Duplicate", children: [.view(view)]))
        ])

        XCTAssertFalse(tree.hasUniqueNodeIDs)
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
