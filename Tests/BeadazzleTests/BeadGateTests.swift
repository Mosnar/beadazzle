import XCTest
@testable import Beadazzle

final class BeadGateTests: XCTestCase {
    func testDecodeTimerGateShowIncludesWaitersAndComputesExpiry() throws {
        let data = Data("""
        {
          "await_type": "timer",
          "created_at": "2026-07-06T12:30:56Z",
          "description": "Ad-hoc gate blocking gatelab-fm4\\n\\nReason: soak overnight for validation",
          "id": "gatelab-y3c",
          "issue_type": "gate",
          "status": "open",
          "timeout": 28800000000000,
          "title": "Gate: timer",
          "updated_at": "2026-07-06T12:31:15Z",
          "waiters": ["gatelab/workers/agent-1", "gatelab/workers/agent-2"]
        }
        """.utf8)

        let gate = try XCTUnwrap(BeadGate.decodeOne(from: data))

        XCTAssertEqual(gate.id, "gatelab-y3c")
        XCTAssertEqual(gate.awaitType, .timer)
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.reason, "soak overnight for validation")
        XCTAssertEqual(gate.blocksIssueID, "gatelab-fm4")
        XCTAssertEqual(gate.waiters, ["gatelab/workers/agent-1", "gatelab/workers/agent-2"])
        XCTAssertEqual(gate.timeoutNanoseconds, 28_800_000_000_000)
        XCTAssertEqual(gate.timeout ?? 0, 28_800, accuracy: 0.5)

        let createdAt = try XCTUnwrap(gate.createdAt)
        let expiresAt = try XCTUnwrap(gate.expiresAt)
        XCTAssertEqual(expiresAt.timeIntervalSince(createdAt), 28_800, accuracy: 0.5)
    }

    func testDecodeListHandlesHumanAndGitHubGates() throws {
        let data = Data("""
        [
          {
            "id": "gatelab2-1dn",
            "title": "Gate: human",
            "description": "Ad-hoc gate blocking gatelab2-gjy\\n\\nReason: need design sign-off",
            "status": "open",
            "await_type": "human"
          },
          {
            "id": "gatelab2-m64",
            "title": "Gate: gh:pr 42",
            "description": "Ad-hoc gate blocking gatelab2-vxb",
            "status": "open",
            "await_type": "gh:pr",
            "await_id": "42"
          }
        ]
        """.utf8)

        let gates = try BeadGate.decodeList(from: data)
        XCTAssertEqual(gates.count, 2)

        let human = try XCTUnwrap(gates.first { $0.id == "gatelab2-1dn" })
        XCTAssertEqual(human.awaitType, .human)
        XCTAssertEqual(human.reason, "need design sign-off")
        XCTAssertNil(human.awaitID)
        XCTAssertNil(human.expiresAt)

        let pr = try XCTUnwrap(gates.first { $0.id == "gatelab2-m64" })
        XCTAssertEqual(pr.awaitType, .githubPR)
        XCTAssertEqual(pr.awaitID, "42")
        XCTAssertNil(pr.reason)
    }

    func testDecodeClosedGateIsNotOpen() throws {
        let data = Data("""
        {"id": "g-1", "await_type": "human", "status": "closed"}
        """.utf8)
        let gate = try XCTUnwrap(BeadGate.decodeOne(from: data))
        XCTAssertFalse(gate.isOpen)
    }

    func testDecodeUnknownAwaitTypeIsPreserved() throws {
        let data = Data("""
        {"id": "g-2", "await_type": "quantum", "status": "open"}
        """.utf8)
        let gate = try XCTUnwrap(BeadGate.decodeOne(from: data))
        XCTAssertEqual(gate.awaitType, .other("quantum"))
        XCTAssertEqual(gate.awaitType.title, "quantum")
        XCTAssertEqual(gate.awaitType.commandValue, "quantum")
    }

    func testDecodeListIsEmptyForNullOutput() throws {
        // `bd gate list --json` emits `null` when there are no gates.
        let gates = try BeadGate.decodeList(from: Data("null".utf8))
        XCTAssertTrue(gates.isEmpty)
    }

    func testAwaitTypeCommandValuesRoundTrip() {
        XCTAssertEqual(GateAwaitType(rawValue: "gh:run"), .githubRun)
        XCTAssertEqual(GateAwaitType(rawValue: "gh:pr"), .githubPR)
        XCTAssertEqual(GateAwaitType.githubRun.commandValue, "gh:run")
        XCTAssertEqual(GateAwaitType.githubPR.commandValue, "gh:pr")
        XCTAssertEqual(GateAwaitType.timer.commandValue, "timer")
    }
}
