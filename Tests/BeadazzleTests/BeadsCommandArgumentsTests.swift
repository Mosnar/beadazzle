import XCTest
@testable import Beadazzle

final class BeadsCommandArgumentsTests: XCTestCase {
    func testCreateArgumentsOmitStatusBecauseCreateDoesNotAcceptStatus() {
        let draft = draft(id: nil, status: "custom-status")

        let arguments = BeadsCommandArguments.create(draft: draft)

        XCTAssertEqual(arguments.first, "create")
        XCTAssertFalse(arguments.contains("--status"))
        XCTAssertFalse(arguments.contains("custom-status"))
    }

    func testUpdateArgumentsIncludeStatusForExistingIssue() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.update(draft: draft(id: "bd-1", status: "review")))

        XCTAssertEqual(arguments.first, "update")
        XCTAssertTrue(arguments.contains("--status"))
        XCTAssertTrue(arguments.contains("review"))
    }

    func testCreateArgumentsNormalizeLabelsAndOmitBlankOptionalFields() {
        let arguments = BeadsCommandArguments.create(
            draft: draft(
                id: nil,
                status: "open",
                description: "",
                assignee: " ",
                labelsText: "area:ui, source:user-report, "
            )
        )

        XCTAssertFalse(arguments.contains("--description"))
        XCTAssertFalse(arguments.contains("--assignee"))
        XCTAssertTrue(arguments.contains("--labels"))
        XCTAssertTrue(arguments.contains("area:ui,source:user-report"))
    }

    func testCreateArgumentsIncludeDueAndDeferredDatesWhenPresent() {
        let arguments = BeadsCommandArguments.create(
            draft: draft(
                id: nil,
                status: "open",
                dueAt: date(year: 2026, month: 7, day: 15),
                deferUntil: date(year: 2026, month: 8, day: 1)
            )
        )

        XCTAssertEqual(value(after: "--due", in: arguments), "2026-07-15")
        XCTAssertEqual(value(after: "--defer", in: arguments), "2026-08-01")
    }

    func testCreateArgumentsIncludeSilentFlagWhenRequested() {
        let arguments = BeadsCommandArguments.create(draft: draft(id: nil, status: "open"), silent: true)

        XCTAssertTrue(arguments.contains("--silent"))
    }

    func testUpdateArgumentsIncludeDueAndDeferredDatesWhenPresent() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.update(
            draft: draft(
                id: "bd-1",
                status: "open",
                dueAt: date(year: 2026, month: 7, day: 15),
                deferUntil: date(year: 2026, month: 8, day: 1)
            )
        ))

        XCTAssertEqual(value(after: "--due", in: arguments), "2026-07-15")
        XCTAssertEqual(value(after: "--defer", in: arguments), "2026-08-01")
    }

    func testUpdateArgumentsClearDueDeferredAndLabelsWhenBlank() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.update(
            draft: draft(
                id: "bd-1",
                status: "open",
                labelsText: " "
            ),
            originalLabels: ["area:ui", "source:user-report"]
        ))

        XCTAssertEqual(value(after: "--due", in: arguments), "")
        XCTAssertEqual(value(after: "--defer", in: arguments), "")
        XCTAssertEqual(values(after: "--remove-label", in: arguments), ["area:ui", "source:user-report"])
        XCTAssertNil(value(after: "--set-labels", in: arguments))
    }

    func testUpdateArgumentsNormalizeReplacementLabels() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.update(
            draft: draft(
                id: "bd-1",
                status: "open",
                labelsText: "area:ui, source:user-report, "
            )
        ))

        XCTAssertEqual(value(after: "--set-labels", in: arguments), "area:ui,source:user-report")
    }

    func testIssueDraftInitializesDatesAndLabelsFromIssue() {
        let dueAt = date(year: 2026, month: 7, day: 15)
        let deferUntil = date(year: 2026, month: 8, day: 1)
        let issue = BeadIssue(
            id: "bd-1",
            title: "Example",
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
            dueAt: dueAt,
            deferUntil: deferUntil,
            externalRef: nil,
            parentID: nil,
            labels: ["area:ui", "source:user-report"],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )

        let draft = IssueDraft(issue: issue)

        XCTAssertEqual(draft.dueAt, dueAt)
        XCTAssertEqual(draft.deferUntil, deferUntil)
        XCTAssertEqual(draft.labels, ["area:ui", "source:user-report"])
    }

    func testAddCommentArgumentsUseStdinForCommentBody() {
        XCTAssertEqual(BeadsCommandArguments.addComment(issueID: "bd-1"), ["comment", "bd-1", "--stdin"])
    }

    func testInitializeArgumentsUseStandardNonInteractiveDefaults() {
        XCTAssertEqual(
            BeadsCommandArguments.initialize(options: BeadsInitOptions()),
            ["init", "--non-interactive", "--role", "maintainer"]
        )
    }

    func testInitializeArgumentsIncludeSelectedOptions() {
        let options = BeadsInitOptions(
            prefix: "custom-prefix",
            usesStealthMode: true,
            skipsAgents: true,
            skipsHooks: true
        )

        XCTAssertEqual(
            BeadsCommandArguments.initialize(options: options),
            [
                "init",
                "--non-interactive",
                "--role",
                "maintainer",
                "--prefix",
                "custom-prefix",
                "--stealth",
                "--skip-agents",
                "--skip-hooks"
            ]
        )
    }

    func testInitializeArgumentsOmitBlankPrefix() {
        let options = BeadsInitOptions(prefix: "  \n")

        XCTAssertEqual(
            BeadsCommandArguments.initialize(options: options),
            ["init", "--non-interactive", "--role", "maintainer"]
        )
    }

    func testExportJSONLArgumentsUseReadableSnapshotPath() {
        XCTAssertEqual(BeadsCommandArguments.exportJSONL(), ["export", "--output", ".beads/issues.jsonl"])
    }

    func testCloseArgumentsIncludeNonBlankReason() {
        XCTAssertEqual(
            BeadsCommandArguments.close(ids: ["bd-1"], reason: "Fixed"),
            ["close", "bd-1", "--reason", "Fixed"]
        )
    }

    func testCloseArgumentsOmitBlankReason() {
        XCTAssertEqual(BeadsCommandArguments.close(ids: ["bd-1"], reason: nil), ["close", "bd-1"])
        XCTAssertEqual(BeadsCommandArguments.close(ids: ["bd-1"], reason: "  \n"), ["close", "bd-1"])
    }

    func testCloseArgumentsSupportMultipleIDsWithReason() {
        XCTAssertEqual(
            BeadsCommandArguments.close(ids: ["bd-1", "bd-2"], reason: "Shipped"),
            ["close", "bd-1", "bd-2", "--reason", "Shipped"]
        )
    }

    func testSaveCustomStatusesSerializesNameCategoryPairs() {
        let arguments = BeadsCommandArguments.saveCustomStatuses([
            BeadStatusDefinition(
                name: "qa",
                category: .wip,
                icon: nil,
                description: nil,
                isBuiltIn: false,
                source: .custom
            ),
            BeadStatusDefinition(
                name: "accepted",
                category: .done,
                icon: nil,
                description: nil,
                isBuiltIn: false,
                source: .custom
            )
        ])

        XCTAssertEqual(arguments, ["config", "set", "status.custom", "qa:wip,accepted:done"])
    }

    func testSaveCustomTypesSerializesNames() {
        let arguments = BeadsCommandArguments.saveCustomTypes([
            BeadTypeDefinition(name: "incident", description: nil, source: .custom),
            BeadTypeDefinition(name: "experiment", description: nil, source: .custom)
        ])

        XCTAssertEqual(arguments, ["config", "set", "types.custom", "incident,experiment"])
    }

    func testSaveCustomConfigUnsetsEmptyValues() {
        XCTAssertEqual(BeadsCommandArguments.saveCustomStatuses([]), ["config", "unset", "status.custom"])
        XCTAssertEqual(BeadsCommandArguments.saveCustomTypes([]), ["config", "unset", "types.custom"])
    }

    func testDecodeCustomStatusesSupportsCategoryAndLegacyEntries() throws {
        let statuses = try BeadsCommandService.decodeCustomStatuses(from: "qa:wip,accepted:done,awaiting_review")

        XCTAssertEqual(statuses.map(\.name), ["qa", "accepted", "awaiting_review"])
        XCTAssertEqual(statuses.map(\.category), [.wip, .done, .uncategorized])
        XCTAssertTrue(statuses.allSatisfy(\.isCustom))
    }

    func testDecodeCustomTypesNormalizesCommaSeparatedNames() throws {
        let types = try BeadsCommandService.decodeCustomTypes(from: "incident, experiment ")

        XCTAssertEqual(types.map(\.name), ["incident", "experiment"])
        XCTAssertTrue(types.allSatisfy(\.isCustom))
    }

    private func draft(
        id: String?,
        status: String,
        description: String = "Description",
        assignee: String = "riley",
        labelsText: String = "area:ui",
        dueAt: Date? = nil,
        deferUntil: Date? = nil
    ) -> IssueDraft {
        IssueDraft(
            id: id,
            title: "Example",
            description: description,
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: status,
            priority: 2,
            issueType: "task",
            assignee: assignee,
            labelsText: labelsText,
            dueAt: dueAt,
            deferUntil: deferUntil
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }

    private func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag,
                  arguments.indices.contains(arguments.index(after: index)) else {
                return nil
            }
            return arguments[arguments.index(after: index)]
        }
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        return components.date!
    }
}
