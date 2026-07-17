import XCTest
@testable import Beadazzle

final class BeadsCommandArgumentsTests: XCTestCase {
    func testSetStateArgumentsUseDimensionValueSyntaxWithReason() {
        XCTAssertEqual(
            BeadsCommandArguments.setState(issueID: "bd-1", dimension: "phase", value: "implementation", reason: "Design proven"),
            ["set-state", "bd-1", "phase=implementation", "--reason", "Design proven"]
        )
    }

    func testSetStateArgumentsOmitEmptyReason() {
        XCTAssertEqual(
            BeadsCommandArguments.setState(issueID: "bd-1", dimension: "phase", value: "implementation", reason: nil),
            ["set-state", "bd-1", "phase=implementation"]
        )
        XCTAssertEqual(
            BeadsCommandArguments.setState(issueID: "bd-1", dimension: "phase", value: "implementation", reason: "  "),
            ["set-state", "bd-1", "phase=implementation"]
        )
    }

    func testCreateArgumentsOmitStatusBecauseCreateDoesNotAcceptStatus() {
        let draft = draft(id: nil, status: "custom-status")

        let arguments = BeadsCommandArguments.create(draft: draft)

        XCTAssertEqual(arguments.first, "create")
        XCTAssertFalse(arguments.contains("--status"))
        XCTAssertFalse(arguments.contains("custom-status"))
    }

    func testUpdateArgumentsIncludeStatusAndLeaveAssigneeToMetadataPath() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.update(draft: draft(id: "bd-1", status: "review")))

        XCTAssertEqual(arguments.first, "update")
        XCTAssertTrue(arguments.contains("--status"))
        XCTAssertTrue(arguments.contains("review"))
        XCTAssertNil(value(after: "--assignee", in: arguments))
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

    func testCreateArgumentsIncludeAssigneeAndLabels() {
        let arguments = BeadsCommandArguments.create(
            draft: draft(
                id: nil,
                status: "open",
                assignee: "Sasha",
                labelsText: "area:ui, source:user-report"
            )
        )

        XCTAssertEqual(value(after: "--assignee", in: arguments), "Sasha")
        XCTAssertEqual(value(after: "--labels", in: arguments), "area:ui,source:user-report")
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

    func testCreateArgumentsIncludeParentWhenPresent() {
        let arguments = BeadsCommandArguments.create(draft: draft(id: nil, status: "open", parentID: "bd-parent"))

        XCTAssertEqual(value(after: "--parent", in: arguments), "bd-parent")
    }

    func testGateShowArgumentsAreReadOnlyJSON() {
        let arguments = BeadsCommandArguments.gateShow(id: "g-1")
        XCTAssertEqual(arguments, ["--readonly", "gate", "show", "g-1", "--json"])
    }

    func testGateResolveOmitsBlankReason() {
        XCTAssertEqual(BeadsCommandArguments.gateResolve(id: "g-1", reason: nil), ["gate", "resolve", "g-1"])
        XCTAssertEqual(BeadsCommandArguments.gateResolve(id: "g-1", reason: "  "), ["gate", "resolve", "g-1"])
    }

    func testGateResolveIncludesReasonWhenPresent() {
        let arguments = BeadsCommandArguments.gateResolve(id: "g-1", reason: "done soaking")
        XCTAssertEqual(value(after: "--reason", in: arguments), "done soaking")
    }

    func testGateCheckFlags() {
        let plain = BeadsCommandArguments.gateCheck(type: nil, escalate: false, dryRun: false)
        XCTAssertEqual(plain, ["gate", "check"])

        let full = BeadsCommandArguments.gateCheck(type: "timer", escalate: true, dryRun: true)
        XCTAssertEqual(value(after: "--type", in: full), "timer")
        XCTAssertTrue(full.contains("--escalate"))
        XCTAssertTrue(full.contains("--dry-run"))
    }

    func testGateCreateUsesTypeCommandValueAndOptionalFlags() {
        let timer = BeadsCommandArguments.gateCreate(blocks: "bd-1", type: .timer, reason: "soak", timeout: "8h", awaitID: nil)
        XCTAssertEqual(Array(timer.prefix(4)), ["gate", "create", "--blocks", "bd-1"])
        XCTAssertEqual(value(after: "--type", in: timer), "timer")
        XCTAssertEqual(value(after: "--timeout", in: timer), "8h")
        XCTAssertEqual(value(after: "--reason", in: timer), "soak")
        XCTAssertFalse(timer.contains("--await-id"))

        let pr = BeadsCommandArguments.gateCreate(blocks: "bd-2", type: .githubPR, reason: nil, timeout: nil, awaitID: "42")
        XCTAssertEqual(value(after: "--type", in: pr), "gh:pr")
        XCTAssertEqual(value(after: "--await-id", in: pr), "42")
        XCTAssertFalse(pr.contains("--timeout"))
        XCTAssertFalse(pr.contains("--reason"))
    }

    func testGateAddWaiterArguments() {
        XCTAssertEqual(
            BeadsCommandArguments.gateAddWaiter(id: "g-1", waiter: "proj/workers/a1"),
            ["gate", "add-waiter", "g-1", "proj/workers/a1"]
        )
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

    func testUpdateArgumentsDiffLabelsWithoutRetransmittingUnchangedState() throws {
        var updatedDraft = draft(id: "bd-1", status: "open", labelsText: "ordinary")
        updatedDraft.labels = ["ordinary", "phase:a,b"]

        let arguments = try XCTUnwrap(BeadsCommandArguments.update(
            draft: updatedDraft,
            originalLabels: ["old", "phase:a,b"]
        ))

        XCTAssertEqual(values(after: "--add-label", in: arguments), ["ordinary"])
        XCTAssertEqual(values(after: "--remove-label", in: arguments), ["old"])
        XCTAssertFalse(arguments.contains("phase:a,b"))
        XCTAssertNil(value(after: "--set-labels", in: arguments))
    }

    func testUpdateArgumentsCSVQuoteAnIndividualCommaLabel() throws {
        var updatedDraft = draft(id: "bd-1", status: "open", labelsText: "")
        updatedDraft.labels = ["release:ready,verified"]

        let arguments = try XCTUnwrap(BeadsCommandArguments.update(
            draft: updatedDraft,
            originalLabels: []
        ))

        XCTAssertEqual(values(after: "--add-label", in: arguments), ["\"release:ready,verified\""])
    }

    func testFullUpdateOmitsBlankAssigneeSoUnrelatedSaveDoesNotClearIt() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.update(
            draft: draft(id: "bd-1", status: "open", assignee: " ")
        ))

        XCTAssertNil(value(after: "--assignee", in: arguments))
    }

    func testMetadataUpdateArgumentsOnlyIncludeMetadataFields() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.updateMetadata(
            issueID: "bd-1",
            assignee: "Sasha",
            labels: ["area:ui", "source:user-report"],
            originalLabels: ["old"],
            dueAt: .set(date(year: 2026, month: 7, day: 15)),
            deferUntil: .set(nil)
        ))

        XCTAssertEqual(Array(arguments.prefix(2)), ["update", "bd-1"])
        XCTAssertFalse(arguments.contains("--title"))
        XCTAssertFalse(arguments.contains("--description"))
        XCTAssertFalse(arguments.contains("--design"))
        XCTAssertFalse(arguments.contains("--acceptance"))
        XCTAssertFalse(arguments.contains("--notes"))
        XCTAssertFalse(arguments.contains("--status"))
        XCTAssertFalse(arguments.contains("--type"))
        XCTAssertFalse(arguments.contains("--priority"))
        XCTAssertEqual(value(after: "--assignee", in: arguments), "Sasha")
        XCTAssertEqual(values(after: "--add-label", in: arguments), ["area:ui", "source:user-report"])
        XCTAssertEqual(values(after: "--remove-label", in: arguments), ["old"])
        XCTAssertNil(value(after: "--set-labels", in: arguments))
        XCTAssertEqual(value(after: "--due", in: arguments), "2026-07-15")
        XCTAssertEqual(value(after: "--defer", in: arguments), "")
    }

    func testMetadataUpdateArgumentsCanClearAssignee() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.updateMetadata(issueID: "bd-1", assignee: " "))

        XCTAssertEqual(value(after: "--assignee", in: arguments), "")
    }

    func testBulkUpdateArgumentsIncludeDeferredDateWhenPresent() {
        let arguments = BeadsCommandArguments.bulkUpdate(
            ids: ["bd-1", "bd-2"],
            status: "deferred",
            deferUntil: .set(date(year: 2026, month: 8, day: 1))
        )

        XCTAssertEqual(value(after: "--status", in: arguments), "deferred")
        XCTAssertEqual(value(after: "--defer", in: arguments), "2026-08-01")
    }

    func testBulkUpdateArgumentsClearDeferredDateWhenSetToNil() {
        let arguments = BeadsCommandArguments.bulkUpdate(
            ids: ["bd-1"],
            status: "deferred",
            deferUntil: .set(nil)
        )

        XCTAssertEqual(value(after: "--status", in: arguments), "deferred")
        XCTAssertEqual(value(after: "--defer", in: arguments), "")
    }

    func testBulkUpdateArgumentsOmitDeferredDateWhenUnchanged() {
        let arguments = BeadsCommandArguments.bulkUpdate(
            ids: ["bd-1"],
            status: "deferred"
        )

        XCTAssertEqual(value(after: "--status", in: arguments), "deferred")
        XCTAssertNil(value(after: "--defer", in: arguments))
    }

    func testMetadataUpdateArgumentsClearLabelsFromOriginalIssue() throws {
        let arguments = try XCTUnwrap(BeadsCommandArguments.updateMetadata(
            issueID: "bd-1",
            labels: [],
            originalLabels: ["area:ui", "source:user-report"]
        ))

        XCTAssertEqual(values(after: "--remove-label", in: arguments), ["area:ui", "source:user-report"])
        XCTAssertNil(value(after: "--set-labels", in: arguments))
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

    func testIssueDraftRoundTripsLabelsContainingCommasQuotesAndEquals() {
        var draft = draft(id: "bd-1", status: "open", labelsText: "ordinary")
        let labels = ["phase:in,review=ready", "quoted:\"value\"", "ordinary"]

        draft.labels = labels

        XCTAssertEqual(draft.labels, labels)
        XCTAssertTrue(draft.labelsText.contains("\"phase:in,review=ready\""))
        XCTAssertTrue(draft.labelsText.contains("\"quoted:\"\"value\"\"\""))
    }

    func testIssueDraftPreservesParentFromIssue() {
        let issue = BeadIssue(
            id: "bd-child",
            title: "Child",
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
            parentID: "bd-parent",
            labels: [],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )

        let draft = IssueDraft(issue: issue)

        XCTAssertEqual(draft.parentID, "bd-parent")
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
        parentID: String? = nil,
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
            parentID: parentID,
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
