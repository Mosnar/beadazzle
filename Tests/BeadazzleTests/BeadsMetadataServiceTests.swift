import XCTest
@testable import Beadazzle

final class BeadsMetadataServiceTests: XCTestCase {
    func testDecodeStatusesPreservesBuiltInSourceAndCategory() throws {
        let data = Data("""
        {
          "built_in_statuses": [
            { "name": "blocked", "category": "wip", "description": "Blocked by dependency" }
          ],
          "custom_statuses": [
            { "name": "qa", "category": "wip" }
          ]
        }
        """.utf8)

        let statuses = try BeadsMetadataService.decodeStatuses(from: data)
        let blocked = try XCTUnwrap(statuses.first { $0.name == "blocked" })
        let qa = try XCTUnwrap(statuses.first { $0.name == "qa" })

        XCTAssertEqual(blocked.category, .wip)
        XCTAssertTrue(blocked.isBuiltIn)
        XCTAssertEqual(blocked.source, .builtIn)
        XCTAssertFalse(qa.isBuiltIn)
        XCTAssertEqual(qa.source, .custom)
    }

    func testDecodeTypesHandlesRecordAndStringShapes() throws {
        let data = Data("""
        {
          "core_types": [
            { "name": "task", "description": "Work item" }
          ],
          "custom_types": ["incident"]
        }
        """.utf8)

        let types = try BeadsMetadataService.decodeTypes(from: data)
        let task = try XCTUnwrap(types.first { $0.name == "task" })
        let incident = try XCTUnwrap(types.first { $0.name == "incident" })

        XCTAssertEqual(Set(types.map(\.name)), ["task", "incident"])
        XCTAssertEqual(task.source, .core)
        XCTAssertEqual(incident.source, .custom)
    }

    func testLoadSemanticsUsesBuiltInCategoriesWithoutCLI() {
        let service = BeadsMetadataService()
        let semantics = service.loadSemantics(
            projectURL: URL(fileURLWithPath: "/tmp/unused"),
            issues: [
                issue("bd-1", status: "open", type: "custom"),
                issue("bd-2", status: "blocked", type: "task"),
                issue("bd-3", status: "closed", type: "task"),
                issue("bd-4", status: "qa", type: "incident")
            ]
        )
        let index = BeadProjectIndex(
            issues: [
                issue("bd-1", status: "open", type: "custom"),
                issue("bd-2", status: "blocked", type: "task"),
                issue("bd-3", status: "closed", type: "task"),
                issue("bd-4", status: "qa", type: "incident")
            ],
            dependencies: [],
            semantics: semantics
        )

        XCTAssertEqual(semantics.category(forStatus: "open"), .active)
        XCTAssertEqual(semantics.category(forStatus: "blocked"), .wip)
        XCTAssertEqual(semantics.category(forStatus: "closed"), .done)
        XCTAssertEqual(semantics.category(forStatus: "qa"), .uncategorized)
        XCTAssertEqual(index.issueIDs(for: .open), ["bd-1"])
        XCTAssertEqual(index.issueIDs(for: .blocked), ["bd-2"])
        XCTAssertEqual(index.issueIDs(for: .closed), ["bd-3"])
        XCTAssertTrue(semantics.typeNames.contains("incident"))
        XCTAssertEqual(semantics.statuses.first { $0.name == "qa" }?.source, .observed)
        XCTAssertEqual(semantics.types.first { $0.name == "incident" }?.source, .observed)
    }

    func testLoadSemanticsExcludesSystemEventTypeFromDefinitionsAndObservedIssues() {
        let semantics = BeadsMetadataService().loadSemantics(
            projectURL: URL(fileURLWithPath: "/tmp/unused"),
            issues: [
                issue("bd-work", status: "open", type: "task"),
                issue("bd-event", status: "event_closed", type: "event")
            ],
            typeDefinitions: [
                BeadTypeDefinition(name: "task", description: nil, source: .core),
                BeadTypeDefinition(name: "event", description: "Internal history", source: .observed)
            ]
        )

        XCTAssertEqual(semantics.typeNames, ["task"])
        XCTAssertFalse(semantics.statusNames.contains("event_closed"))
    }

    private func issue(_ id: String, status: String, type: String) -> BeadIssue {
        BeadIssue(
            id: id,
            title: "Example",
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: status,
            priority: 2,
            issueType: type,
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
