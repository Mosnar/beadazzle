import XCTest
@testable import Beadazzle

final class DetailSectionLayoutTests: XCTestCase {
    func testReportedEpicAndLargerSubtreeUseTheContributedWorkaround() {
        let comments = [2549, 1302, 542].enumerated().map {
            comment(id: "\($0.offset)", text: String(repeating: "x", count: $0.element))
        }
        for children in [7, 28] {
            let events = (0...children).map { event(id: "\($0)") }
            XCTAssertEqual(DetailSectionLayout.activity(events + comments), .eager)
            XCTAssertEqual(DetailSectionLayout.subIssues(count: children), .eager)
        }
    }

    func testLargeFeedsAndSubtreesKeepLazyLoading() {
        let items = (0..<1000).map { event(id: "\($0)") }
        XCTAssertEqual(DetailSectionLayout.activity(items), .lazy)
        XCTAssertEqual(DetailSectionLayout.subIssues(count: 1000), .lazy)
    }

    func testSmallFeedWithLongCommentsStillUsesTheWorkaround() {
        let text = String(repeating: "A long wrapped comment. ", count: 400)
        let items = (0..<12).map { comment(id: "\($0)", text: text) }
        XCTAssertEqual(DetailSectionLayout.activity(items), .eager)
    }

    func testLongEventReasonsAlsoLimitEagerLayout() {
        let reason = String(repeating: "A detailed close reason. ", count: 20000)
        XCTAssertEqual(DetailSectionLayout.activity([event(id: "closed", reason: reason)]), .lazy)
    }

    func testActivityAndSubIssueRowLimits() {
        let items = (0..<64).map { event(id: "\($0)") }
        XCTAssertEqual(DetailSectionLayout.activity(items), .eager)
        XCTAssertEqual(DetailSectionLayout.activity(items + [event(id: "next")]), .lazy)
        XCTAssertEqual(DetailSectionLayout.subIssues(count: 64), .eager)
        XCTAssertEqual(DetailSectionLayout.subIssues(count: 65), .lazy)
    }

    func testTextLimitCountsBytesAcrossTheWholeFeed() {
        let half = String(repeating: "é", count: 64 * 1024)
        let items = [comment(id: "first", text: half), comment(id: "second", text: half)]
        XCTAssertEqual(DetailSectionLayout.activity(items), .eager)
        XCTAssertEqual(DetailSectionLayout.activity(items + [comment(id: "next", text: "x")]), .lazy)
    }

    func testLayoutDoesNotSwitchBackWhenTheSameSectionShrinks() {
        var layout = DetailSectionLayout.eager
        let observed = [DetailSectionLayout.eager, .lazy, .eager, .lazy, .eager].map { next in
            layout = next.retainingLazyLayout(from: layout)
            return layout
        }
        XCTAssertEqual(observed, [.eager, .lazy, .lazy, .lazy, .lazy])
        // Opening another issue starts a fresh section.
        XCTAssertEqual(DetailSectionLayout.eager.retainingLazyLayout(from: .eager), .eager)
    }

    private func comment(id: String, text: String) -> IssueActivityItem {
        .comment(BeadComment(
            id: id, issueID: "epic", author: "Test author", text: text,
            createdAt: nil, updatedAt: nil
        ))
    }

    private func event(id: String, reason: String? = nil) -> IssueActivityItem {
        .event(IssueActivityEventPresentation(
            id: id, date: nil, actor: nil, systemImage: "circle",
            message: "updated this bead", reason: reason
        ))
    }
}
