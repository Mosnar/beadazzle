import AppKit
import XCTest
@testable import Beadazzle

final class BeadIconographyTests: XCTestCase {
    func testSharedSymbolsResolveToRealSFSymbols() {
        let symbols = [
            BeadIconography.blockedBy,
            BeadIconography.blocking,
            BeadIconography.children,
            BeadIconography.genericGate,
            BeadIconography.externalReference,
            BeadIconography.humanGate,
            BeadIconography.plainTimerGate,
            BeadIconography.timerGate
        ]
        for symbol in symbols {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(symbol) is not a valid SF Symbol on this system"
            )
        }
    }

    func testPreferredTimerGateSymbolResolvesWhereSupported() {
        // Guards against a typo in the preferred name: resolvedSystemName would
        // silently fall back to the plain timer symbol on every system, so assert
        // the preferred name itself resolves on systems that ship it.
        if #available(macOS 15.4, *) {
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: BeadIconography.preferredTimerGate,
                    accessibilityDescription: nil
                )
            )
        }
    }

    func testResolvedSystemNameUsesPreferredNameOrFallback() {
        XCTAssertEqual(
            BeadIconography.resolvedSystemName(
                preferred: "nosign.badge.clock",
                fallback: "timer",
                isAvailable: { _ in true }
            ),
            "nosign.badge.clock"
        )
        XCTAssertEqual(
            BeadIconography.resolvedSystemName(
                preferred: "nosign.badge.clock",
                fallback: "timer",
                isAvailable: { _ in false }
            ),
            "timer"
        )
    }

    func testClosedTimerGateUsesNeutralTimerSymbol() {
        var gate = BeadGate(
            id: "g-1",
            title: "Gate",
            awaitType: .timer,
            status: "open",
            reason: nil,
            awaitID: nil,
            timeoutNanoseconds: nil,
            createdAt: nil,
            updatedAt: nil,
            waiters: [],
            blocksIssueID: nil
        )
        XCTAssertEqual(gate.systemImage, BeadIconography.timerGate)

        gate.status = "closed"
        XCTAssertEqual(gate.systemImage, BeadIconography.plainTimerGate)

        gate.awaitType = .human
        XCTAssertEqual(gate.systemImage, BeadIconography.humanGate)
    }
}
