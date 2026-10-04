import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Beadazzle

/// Opt-in measurements of the real detail page. Timings are evidence, not test limits.
/// Run serially with BEADAZZLE_DETAIL_BENCH=1 swift test --filter DetailScrollBenchmark.
@MainActor
final class DetailScrollBenchmark: XCTestCase {
    func testNativeDetailScrolling() async throws {
        guard ProcessInfo.processInfo.environment["BEADAZZLE_DETAIL_BENCH"] == "1" else {
            throw XCTSkip("Set BEADAZZLE_DETAIL_BENCH=1 to measure native detail scrolling")
        }
        _ = NSApplication.shared
        // PR #6's seed puts three comments on the selected epic. Comments on its
        // children do not appear in that epic's Activity section.
        let scenarios: [(String, [Int], Int)] = [
            ("control", [], 2),
            ("repro", [2549, 1302, 542], 7),
            ("repro-4x", [2549, 1302, 542], 28),
            ("short-48", Array(repeating: 200, count: 48), 0),
            ("long-12", Array(repeating: 8000, count: 12), 0),
            ("comments-200", (0..<200).map { 250 + ($0 % 15) * 83 }, 0),
            ("comments-1000", (0..<1000).map { 250 + ($0 % 15) * 83 }, 0),
            ("children-1000", [], 1000)
        ]
        for (name, lengths, children) in scenarios {
            for width in [650.0, 1200.0] {
                try await measure(name: name, commentLengths: lengths, children: children, width: width)
            }
        }
    }

    func testRetainedWindowAcrossLayoutBudgetAndWidthChanges() async throws {
        guard ProcessInfo.processInfo.environment["BEADAZZLE_DETAIL_BENCH"] == "1" else {
            throw XCTSkip("Set BEADAZZLE_DETAIL_BENCH=1 to measure native detail scrolling")
        }
        _ = NSApplication.shared
        let (store, root) = makeStore(commentLengths: [2549, 1302, 542], children: 7)
        store.updateCommentDraft("Keep this comment draft", issueID: root.id)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1200, height: 750),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: DetailView(requestClose: { _ in }).environment(store))
        window.contentView = host
        window.orderFront(nil)

        let lengthsByStep = [
            Array(repeating: 200, count: 56), Array(repeating: 200, count: 57),
            Array(repeating: 200, count: 56), Array(repeating: 8000, count: 12),
            [2549, 1302, 542]
        ]
        for lengths in lengthsByStep {
            store.commentCache[root.id] = comments(lengths: lengths, issue: root)
            store.syncCommentsForSelectionFromCache()
            for width in [650, 1200, IssueDetailLayout.railBreakpoint - 1, IssueDetailLayout.railBreakpoint + 1] {
                window.setContentSize(NSSize(width: width, height: 750))
                try await Task.sleep(for: .milliseconds(150))
                let scroll = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height })
                for step in 0..<16 {
                    let event = try XCTUnwrap(CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: step < 10 ? -150 : 150, wheel2: 0, wheel3: 0
                    ))
                    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
                    try await Task.sleep(for: .milliseconds(16))
                }
            }
            XCTAssertEqual(store.comments(for: root.id).count, lengths.count)
            XCTAssertEqual(store.commentDraft(for: root.id), "Keep this comment draft")
        }

        // The same DetailView also survives ordinary selection changes.
        for issueID in ["scroll-0", root.id] {
            store.select([issueID])
            store.syncCommentsForSelectionFromCache()
            store.prepareActivityForSelection()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(store.selectedIssue?.id, issueID)
        }
        XCTAssertEqual(store.commentDraft(for: root.id), "Keep this comment draft")
        let cpuStart = cpuSeconds()
        try await Task.sleep(for: .seconds(5))
        print("DETAIL_SCROLL_RETAINED idle_cpu_s=\(cpuSeconds() - cpuStart) idle_wall_s=5 transitions=5 widths=4")
        fflush(stdout)
    }

    private func makeStore(commentLengths: [Int], children: Int) -> (BeadStore, BeadIssue) {
        let store = BeadStore(userDefaults: makeIsolatedUserDefaults())
        let root = issue("scroll-root")
        let childIssues = (0..<children).map { issue("scroll-\($0)", parentID: root.id) }
        let dependencies = childIssues.map {
            BeadDependency(issueID: $0.id, dependsOnID: root.id, type: "parent-child", createdAt: root.createdAt)
        }
        store.index = BeadProjectIndex(issues: [root] + childIssues, dependencies: dependencies, semantics: .empty)
        store.authoritativeIndex = store.index
        store._selectedIDs = [root.id]
        store.commentCache[root.id] = comments(lengths: commentLengths, issue: root)
        store.syncCommentsForSelectionFromCache()
        store.prepareActivityForSelection()
        store.activityLoadedIssueID = root.id
        XCTAssertEqual(store.comments(for: root.id).count, commentLengths.count)
        XCTAssertEqual(store.subIssueRows(parentID: root.id).count, children)
        return (store, root)
    }

    private func comments(lengths: [Int], issue: BeadIssue) -> [BeadComment] {
        let text = "The deploy stage reads the pinned tag and checks the image before the deployment starts. "
        return lengths.enumerated().map { index, length in
            BeadComment(
                id: "scroll-comment-\(index)", issueID: issue.id, author: "Test author",
                text: String(String(repeating: text, count: length / text.count + 1).prefix(length)),
                createdAt: issue.createdAt?.addingTimeInterval(Double(index + 1) * 9000), updatedAt: nil
            )
        }
    }

    private func measure(name: String, commentLengths: [Int], children: Int, width: Double) async throws {
        let (store, root) = makeStore(commentLengths: commentLengths, children: children)
        let page = IssueDetailPage(
            issue: root, draft: .constant(IssueDraft(issue: root)),
            textSectionLayout: .init(visible: [.description], hidden: []),
            revealTextSection: { _ in }, hideTextSection: { _ in }, isDirty: false,
            saveAction: {}, revertAction: {}, requestClose: { _ in }
        ).environment(store)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: width, height: 750),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let start = CFAbsoluteTimeGetCurrent()
        let host = NSHostingView(rootView: page)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let initialMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        try await Task.sleep(for: .milliseconds(300))

        let scroll = try XCTUnwrap(scrollViews(in: host).max { $0.frame.height < $1.frame.height })
        let scrollCPUStart = cpuSeconds()
        var heights: [Double] = []
        var maxOffset = 0.0
        var maxTick = 0.0
        for step in 0..<80 {
            let tick = CFAbsoluteTimeGetCurrent()
            let event = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: step < 50 ? -150 : 150, wheel2: 0, wheel3: 0
            ))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
            try await Task.sleep(for: .milliseconds(16))
            maxTick = max(maxTick, CFAbsoluteTimeGetCurrent() - tick)
            heights.append(Double(scroll.documentView?.frame.height ?? 0))
            maxOffset = max(maxOffset, scroll.contentView.bounds.minY)
        }
        let scrollCPU = cpuSeconds() - scrollCPUStart
        let idleStart = cpuSeconds()
        try await Task.sleep(for: .seconds(1))
        let idleCPU = cpuSeconds() - idleStart
        if name != "control" { XCTAssertGreaterThan(maxOffset, 0) }
        let record: [String: Any] = [
            "variant": ProcessInfo.processInfo.environment["BEADAZZLE_DETAIL_VARIANT"] ?? "current",
            "scenario": name, "width": width, "activity_items": store.activityItems.count,
            "initial_ms": initialMilliseconds, "scroll_cpu_s": scrollCPU, "idle_cpu_s": idleCPU,
            "max_tick_ms": maxTick * 1000, "max_offset": maxOffset,
            "height_delta": (heights.max() ?? 0) - (heights.min() ?? 0)
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("DETAIL_SCROLL_RESULT " + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    private func issue(_ id: String, parentID: String? = nil) -> BeadIssue {
        BeadIssue(
            id: id, title: "Release model and deployment checks \(id)",
            description: String(repeating: "A synthetic description for the detail scroll test. ", count: 14),
            design: "", acceptanceCriteria: "", notes: "", status: "open", priority: 2,
            issueType: parentID == nil ? "epic" : "task", assignee: nil, owner: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), updatedAt: nil, closedAt: nil,
            dueAt: nil, deferUntil: nil, externalRef: nil, parentID: parentID, labels: [],
            dependencyCount: 0, dependentCount: 0, commentCount: 0,
            pinned: false, ephemeral: false, isTemplate: false
        )
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}
