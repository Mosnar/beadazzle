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
        time("outline rows (collapsed)") {
            _ = index.issueListRows(for: filtered, mode: .outline, expandedIssueIDs: [], sortOrder: sortOrder)
        }
        time("outline rows (all expanded)") {
            _ = index.issueListRows(for: filtered, mode: .outline, expandedIssueIDs: Set(filtered), sortOrder: sortOrder)
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

            let sortOrder = BeadIssueSortOrder(sort: .priority, direction: .ascending)
            time("outline rows (collapsed)") {
                _ = index.issueListRows(for: filtered, mode: .outline, expandedIssueIDs: [], sortOrder: sortOrder)
            }
            let allExpanded = Set(filtered)
            time("outline rows (all expanded)") {
                _ = index.issueListRows(for: filtered, mode: .outline, expandedIssueIDs: allExpanded, sortOrder: sortOrder)
            }
            time("flat rows") {
                _ = index.issueListRows(for: filtered, mode: .flat, expandedIssueIDs: [], sortOrder: sortOrder)
            }
        }
    }
}
