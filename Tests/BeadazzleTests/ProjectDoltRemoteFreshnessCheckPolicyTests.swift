import Foundation
import XCTest
@testable import Beadazzle

final class ProjectDoltRemoteFreshnessCheckPolicyTests: XCTestCase {
    func testAutomaticCheckWithoutCheckpointShowsCacheWithoutProbing() {
        XCTAssertEqual(
            decision(record: record()),
            .showCached(preservesUnavailable: false)
        )
        XCTAssertEqual(
            decision(record: record(lastAttemptedAt: Date())),
            .showCached(preservesUnavailable: true)
        )
    }

    func testAutomaticCheckUsesBackoffBeforeSceneEligibility() {
        let now = Date()
        XCTAssertEqual(
            decision(
                record: record(
                    checkpoint: "generation",
                    lastAttemptedAt: now.addingTimeInterval(-10)
                ),
                automaticallyChecks: false,
                hasActiveScene: false,
                now: now
            ),
            .showCached(preservesUnavailable: true)
        )
    }

    func testExpiredAutomaticCheckRequiresPreferenceAndActiveScene() {
        let now = Date()
        let expiredRecord = record(
            checkpoint: "generation",
            lastAttemptedAt: now.addingTimeInterval(-301)
        )

        XCTAssertEqual(
            decision(record: expiredRecord, hasActiveScene: false, now: now),
            .showCached(preservesUnavailable: false)
        )
        XCTAssertEqual(
            decision(record: expiredRecord, now: now),
            .probe
        )
    }

    func testManualAndCheckpointChecksAlwaysProbe() {
        let candidate = record()
        XCTAssertEqual(
            decision(kind: .manual, record: candidate, automaticallyChecks: false),
            .probe
        )
        XCTAssertEqual(
            decision(
                kind: .establishSyncCheckpoint,
                record: candidate,
                automaticallyChecks: false,
                isChecking: true
            ),
            .probe
        )
    }

    private func decision(
        kind: ProjectDoltRemoteFreshnessCheckKind = .automatic,
        record: ProjectDoltRemoteFreshnessRecord,
        automaticallyChecks: Bool = true,
        hasActiveScene: Bool = true,
        isChecking: Bool = false,
        now: Date = Date()
    ) -> ProjectDoltRemoteFreshnessCheckDecision {
        ProjectDoltRemoteFreshnessCheckPolicy.decision(
            kind: kind,
            record: record,
            automaticallyChecks: automaticallyChecks,
            hasActiveScene: hasActiveScene,
            isChecking: isChecking,
            now: now,
            checkInterval: 300
        )
    }

    private func record(
        checkpoint: String? = nil,
        lastAttemptedAt: Date? = nil
    ) -> ProjectDoltRemoteFreshnessRecord {
        ProjectDoltRemoteFreshnessRecord(
            remoteName: "origin",
            remoteFingerprint: "fingerprint",
            syncCheckpointGeneration: checkpoint,
            observedGeneration: checkpoint,
            lastCheckedAt: lastAttemptedAt,
            lastAttemptedAt: lastAttemptedAt
        )
    }
}
