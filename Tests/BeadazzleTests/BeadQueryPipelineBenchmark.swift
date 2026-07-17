import XCTest
@testable import Beadazzle

/// Throwaway wall-clock benchmark for the off-main query pipeline at Linear scale.
/// Not an assertion suite — it prints timings so we can see where the time goes.
final class BeadQueryPipelineBenchmark: XCTestCase {
    private func makeSemantics() -> BeadProjectSemantics {
        BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "todo", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "doing", category: .wip, icon: nil, description: nil),
                BeadStatusDefinition(name: "done", category: .done, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "task", description: nil),
                BeadTypeDefinition(name: "bug", description: nil)
            ]
        )
    }

    private func makeIssues(_ count: Int) -> [BeadIssue] {
        (0..<count).map { i in
            BeadIssue(
                id: "bd-\(i)",
                title: i.isMultiple(of: 2) ? "Crawler pipeline task \(i)" : "Portal navigation issue \(i)",
                description: "Detailed description for bead \(i) covering the reproduction steps, expected behavior, and observed regression across the affected surfaces.",
                design: "Design notes for \(i): keep the sidebar native and the list compact.",
                acceptanceCriteria: "Given a project with \(i) beads, when the user filters, then results appear instantly.",
                notes: "Follow-up notes \(i)",
                status: i.isMultiple(of: 5) ? "done" : (i.isMultiple(of: 3) ? "doing" : "todo"),
                priority: i % 4,
                issueType: i.isMultiple(of: 7) ? "bug" : "task",
                assignee: "user\(i % 20)",
                owner: "owner\(i % 10)",
                createdAt: nil, updatedAt: nil, closedAt: nil, dueAt: nil, deferUntil: nil,
                externalRef: "EXT-\(i)",
                // Every 4th issue is a child of a nearby issue, to build a real outline tree.
                parentID: (i % 4 == 0 && i > 0) ? "bd-\(i - 1)" : nil,
                labels: [i.isMultiple(of: 2) ? "crawler" : "portal", "team-\(i % 8)"],
                dependencyCount: 0, dependentCount: 0, commentCount: i % 3,
                pinned: false, ephemeral: false, isTemplate: false
            )
        }
    }

    private func outlineIssue(id: String, title: String, parentID: String?) -> BeadIssue {
        BeadIssue(
            id: id,
            title: title,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: "todo",
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
            parentID: parentID,
            labels: [],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }

    private func time(_ label: String, iterations: Int = 5, _ body: () -> Void) {
        // Warm up once.
        body()
        let clock = ContinuousClock()
        var best = Duration.seconds(1_000)
        for _ in 0..<iterations {
            let elapsed = clock.measure(body)
            if elapsed < best { best = elapsed }
        }
        let ms = Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1000
        print(String(format: "PERF  %-28@  best-of-%d  %8.3f ms", label as NSString, iterations, ms))
    }

    /// Loads a real Beads project from BEADAZZLE_BENCH_PROJECT and times the pipeline
    /// against its actual data. Skipped when the env var is unset.
    func testPipelineTimingsAgainstRealProject() throws {
        guard let path = ProcessInfo.processInfo.environment["BEADAZZLE_BENCH_PROJECT"] else {
            throw XCTSkip("Set BEADAZZLE_BENCH_PROJECT to a project dir to run the real-data benchmark")
        }
        let projectURL = URL(fileURLWithPath: path, isDirectory: true)
        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)
        let snapshot = loaded.snapshot
        let semantics = BeadsMetadataService().loadSemantics(projectURL: projectURL, issues: snapshot.issues)

        print("\n===== REAL project: \(snapshot.issues.count) issues, \(snapshot.dependencies.count) deps (\(loaded.source.kind)) =====")

        var index = BeadProjectIndex.empty
        time("index build") {
            index = BeadProjectIndex(issues: snapshot.issues, dependencies: snapshot.dependencies, semantics: semantics)
        }
        let allIDs = index.issueIDs(for: .all)
        var filtered: [String] = []
        time("filter (no search)") {
            filtered = index.filteredIssueIDs(within: allIDs, statusFilters: [], typeFilters: [], priorityFilters: [], labelFilters: [], searchText: "")
        }
        time("filter (search 'crawler')") {
            _ = index.filteredIssueIDs(within: allIDs, statusFilters: [], typeFilters: [], priorityFilters: [], labelFilters: [], searchText: "crawler")
        }
        time("filter (search 'a')") {
            _ = index.filteredIssueIDs(within: allIDs, statusFilters: [], typeFilters: [], priorityFilters: [], labelFilters: [], searchText: "a")
        }
        let sortOrder = BeadIssueSortOrder(sort: .priority, direction: .ascending)
        var sorted: [String] = []
        time("sort") {
            sorted = index.sortedIssueIDs(filtered, sortOrder: sortOrder)
        }
        time("sort + outline (collapsed)") {
            let ids = index.sortedIssueIDs(filtered, sortOrder: sortOrder)
            _ = index.issueListRows(
                for: ids,
                mode: .outline,
                expandedIssueIDs: [],
                sortOrder: sortOrder,
                filteredIssueIDsAreSorted: true
            )
        }
        time("outline rows (collapsed)") {
            _ = index.issueListRows(
                for: sorted,
                mode: .outline,
                expandedIssueIDs: [],
                sortOrder: sortOrder,
                filteredIssueIDsAreSorted: true
            )
        }
        time("outline rows (all expanded)") {
            _ = index.issueListRows(
                for: sorted,
                mode: .outline,
                expandedIssueIDs: Set(sorted),
                sortOrder: sortOrder,
                filteredIssueIDsAreSorted: true
            )
        }
    }

    func testPipelineTimingsAtScale() throws {
        guard ProcessInfo.processInfo.environment["BEADAZZLE_BENCH"] != nil else {
            throw XCTSkip("Set BEADAZZLE_BENCH=1 to run the synthetic scale benchmark")
        }
        for scale in [1_000, 5_000, 10_000] {
            print("\n===== \(scale) beads =====")
            let semantics = makeSemantics()
            let issues = makeIssues(scale)

            var index = BeadProjectIndex.empty
            time("index build") { index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics) }

            let allIDs = index.issueIDs(for: .all)
            var filtered: [String] = []
            time("filter (no search)") {
                filtered = index.filteredIssueIDs(
                    within: allIDs, statusFilters: [], typeFilters: [],
                    priorityFilters: [], labelFilters: [], searchText: ""
                )
            }
            time("filter (search 'task')") {
                _ = index.filteredIssueIDs(
                    within: allIDs, statusFilters: [], typeFilters: [],
                    priorityFilters: [], labelFilters: [], searchText: "task"
                )
            }
            time("filter (search 'navigation')") {
                _ = index.filteredIssueIDs(
                    within: allIDs, statusFilters: [], typeFilters: [],
                    priorityFilters: [], labelFilters: [], searchText: "navigation"
                )
            }

            let savedViews = (0..<25).map { offset in
                let condition = BeadFilterCondition(
                    field: .owner,
                    operation: .isAnyOf,
                    value: BeadFilterValue(strings: ["owner\(offset % 10)"])
                )
                return BeadSavedViewQuery(
                    basePreset: .all,
                    statusFilters: [], typeFilters: [], priorityFilters: [], labelFilters: [], searchText: "",
                    advancedPredicate: BeadFilterGroup(children: [.condition(condition)])
                )
            }
            let savedViewEntries = savedViews.map { (id: UUID(), filter: $0) }
            time("25 saved-view counts", iterations: 3) {
                _ = BeadSavedViewQueryEvaluator.matchingIssueCounts(
                    index: index,
                    filters: savedViewEntries
                )
            }

            let sortOrder = BeadIssueSortOrder(sort: .priority, direction: .ascending)
            var sorted: [String] = []
            time("sort") {
                sorted = index.sortedIssueIDs(filtered, sortOrder: sortOrder)
            }
            time("sort + outline (collapsed)") {
                let ids = index.sortedIssueIDs(filtered, sortOrder: sortOrder)
                _ = index.issueListRows(
                    for: ids,
                    mode: .outline,
                    expandedIssueIDs: [],
                    sortOrder: sortOrder,
                    filteredIssueIDsAreSorted: true
                )
            }
            time("outline rows (collapsed)") {
                _ = index.issueListRows(
                    for: sorted,
                    mode: .outline,
                    expandedIssueIDs: [],
                    sortOrder: sortOrder,
                    filteredIssueIDsAreSorted: true
                )
            }
            let allExpanded = Set(sorted)
            time("outline rows (all expanded)") {
                _ = index.issueListRows(
                    for: sorted,
                    mode: .outline,
                    expandedIssueIDs: allExpanded,
                    sortOrder: sortOrder,
                    filteredIssueIDsAreSorted: true
                )
            }
            time("flat rows") {
                _ = index.issueListRows(
                    for: sorted,
                    mode: .flat,
                    expandedIssueIDs: [],
                    sortOrder: sortOrder,
                    filteredIssueIDsAreSorted: true
                )
            }
        }
    }

    func testOutlineStressTimingsAtScale() throws {
        guard ProcessInfo.processInfo.environment["BEADAZZLE_BENCH"] != nil else {
            throw XCTSkip("Set BEADAZZLE_BENCH=1 to run the synthetic scale benchmark")
        }

        let scale = 10_000
        let semantics = makeSemantics()
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        do {
            let issues = (0..<scale).map { offset in
                outlineIssue(
                    id: "deep-\(offset)",
                    title: String(format: "Deep issue %05d", offset),
                    parentID: offset == 0 ? nil : "deep-\(offset - 1)"
                )
            }
            let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics)
            let matchingIDs = ["deep-\(scale - 1)"]
            let rows = index.issueListRows(
                for: matchingIDs,
                mode: .outline,
                expandedIssueIDs: [],
                sortOrder: sortOrder,
                filteredIssueIDsAreSorted: true
            )
            XCTAssertEqual(rows.count, scale)

            time("outline sparse deep context", iterations: 3) {
                _ = index.issueListRows(
                    for: matchingIDs,
                    mode: .outline,
                    expandedIssueIDs: [],
                    sortOrder: sortOrder,
                    filteredIssueIDsAreSorted: true
                )
            }
        }

        do {
            let rootID = "sibling-root"
            let childIDs = (1..<scale).map { "sibling-\($0)" }
            let issues = [outlineIssue(id: rootID, title: "Root", parentID: nil)]
                + childIDs.enumerated().map { offset, issueID in
                    outlineIssue(
                        id: issueID,
                        title: String(format: "Sibling %05d", offset),
                        parentID: rootID
                    )
                }
            let dependencies = zip(childIDs.dropLast(), childIDs.dropFirst()).map { pair in
                BeadDependency(
                    issueID: pair.0,
                    dependsOnID: pair.1,
                    type: "blocks",
                    createdAt: nil
                )
            }
            let index = BeadProjectIndex(
                issues: issues,
                dependencies: dependencies,
                semantics: semantics
            )
            let sortedIDs = index.sortedIssueIDs([rootID] + childIDs, sortOrder: sortOrder)
            let rows = index.issueListRows(
                for: sortedIDs,
                mode: .outline,
                expandedIssueIDs: [rootID],
                sortOrder: sortOrder,
                filteredIssueIDsAreSorted: true
            )
            XCTAssertEqual(rows.count, scale)

            time("outline blocking siblings", iterations: 3) {
                _ = index.issueListRows(
                    for: sortedIDs,
                    mode: .outline,
                    expandedIssueIDs: [rootID],
                    sortOrder: sortOrder,
                    filteredIssueIDsAreSorted: true
                )
            }
        }
    }
}
