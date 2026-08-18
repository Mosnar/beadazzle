import Foundation

/// A Beads schema mismatch detected from `bd`'s own refusal to open a database.
///
/// Direction is safety-critical. A database behind the binary can use `bd migrate`;
/// a database ahead of the binary must never enter that path. The failure text is the
/// signal `bd` gives us, so both supported phrasings are parsed here.
enum BeadsSchemaSkewDirection: Equatable, Sendable {
    case databaseBehind
    case databaseAhead
    case unknown
}

enum BeadsSchemaSkewResolution: Equatable, Sendable {
    case upwardMigration
    case guidedRecovery
    case compatibleBinary
    case manualRecovery

    var title: String {
        switch self {
        case .upwardMigration: "This Tracker Needs an Upgrade"
        case .guidedRecovery: "This Tracker Needs Guided Recovery"
        case .compatibleBinary: "This Tracker Needs a Compatible bd Binary"
        case .manualRecovery: "This Tracker Needs Manual Recovery"
        }
    }

    var healthSummary: String {
        switch self {
        case .upwardMigration: "This tracker needs a one-time upgrade"
        case .guidedRecovery: "This tracker needs guided recovery"
        case .compatibleBinary: "This tracker needs a compatible bd binary"
        case .manualRecovery: "This tracker has an unclassified schema mismatch"
        }
    }

    var actionHint: String {
        switch self {
        case .upwardMigration:
            "Upgrade the tracker to continue."
        case .guidedRecovery:
            "Review the backup-first v65-to-v53 recovery."
        case .compatibleBinary:
            "Use a compatible tested bd binary or follow the official recovery guide manually."
        case .manualRecovery:
            "Review the official recovery guide; Beadazzle will not modify this tracker automatically."
        }
    }

    var guidance: String {
        switch self {
        case .upwardMigration:
            "A newer version of bd needs to upgrade this tracker's database once before Beadazzle can read it."
        case .guidedRecovery:
            "The installed bd 1.2.2 binary is healthy. Review the pinned backup-first recovery before changing this exact v65 tracker; reinstalling accidental bd 1.2.0/1.2.1 is not the fix."
        case .compatibleBinary:
            "This database is newer than the installed bd binary, but it is not the pinned v65/v53 incident. Use a compatible tested bd binary or follow the official recovery guide manually. Reinstalling accidental bd 1.2.0/1.2.1 is not a fix."
        case .manualRecovery:
            "Beadazzle could not prove the mismatch direction, so it will not modify the tracker. Use a compatible bd binary or follow the official recovery guide manually."
        }
    }

    var errorDescription: String {
        switch self {
        case .upwardMigration:
            "This tracker needs a one-time upgrade for the installed version of `bd`."
        case .guidedRecovery:
            "This tracker was migrated by a newer unsupported bd release. The installed tested bd binary is healthy; review recovery before making any tracker changes."
        case .compatibleBinary:
            "This tracker requires a compatible tested bd binary or a reviewed manual recovery."
        case .manualRecovery:
            "This tracker has an unclassified schema mismatch. Beadazzle will keep it read-only until a compatible bd binary or a reviewed manual recovery is available."
        }
    }

    var systemImage: String {
        switch self {
        case .upwardMigration: "arrow.up.circle.fill"
        case .guidedRecovery: "cross.case.fill"
        case .compatibleBinary, .manualRecovery: "exclamationmark.octagon.fill"
        }
    }
}

struct BeadsSchemaSkew: Equatable, Sendable {
    /// The schema version currently stored in the tracker database.
    var databaseVersion: Int?
    /// The schema version the installed `bd` binary expects.
    var binaryVersion: Int?
    /// Direction explicitly reported by `bd` when one or both versions could not be
    /// parsed. Parsed version ordering takes precedence when both are available.
    var reportedDirection: BeadsSchemaSkewDirection? = nil

    var direction: BeadsSchemaSkewDirection {
        if let databaseVersion, let binaryVersion {
            if databaseVersion < binaryVersion { return .databaseBehind }
            if databaseVersion > binaryVersion { return .databaseAhead }
            return .unknown
        }
        return reportedDirection ?? .unknown
    }

    var resolution: BeadsSchemaSkewResolution {
        switch direction {
        case .databaseBehind:
            .upwardMigration
        case .databaseAhead where supportsPinnedV65ToV53Recovery:
            .guidedRecovery
        case .databaseAhead:
            .compatibleBinary
        case .unknown:
            .manualRecovery
        }
    }

    /// The only forward-skew incident for which the pinned bd 1.2.2 guide authorizes
    /// automatic repair.
    var supportsPinnedV65ToV53Recovery: Bool {
        direction == .databaseAhead
            && databaseVersion == 65
            && binaryVersion == 53
    }

    var versionSummary: String? {
        guard let databaseVersion, let binaryVersion else { return nil }
        switch direction {
        case .databaseBehind:
            return "Database is at v\(databaseVersion); bd expects v\(binaryVersion)."
        case .databaseAhead, .unknown:
            return "Database is at v\(databaseVersion); bd supports up to v\(binaryVersion)."
        }
    }

    /// Matches both `bd` schema-mismatch refusals, e.g.
    /// `schema version mismatch: database is at v53, binary expects v65, and the
    /// read-only open cannot migrate it; run any bd write command in that workspace
    /// to migrate` and `database is at v65, binary knows up to v53`.
    ///
    /// The version numbers are parsed when present but are not required — the
    /// mismatch phrase alone is enough to keep the tracker read-only, even when its
    /// direction cannot be proven.
    static func detect(in text: String) -> BeadsSchemaSkew? {
        let lowercased = text.lowercased()
        let reportedDirection = reportedDirection(in: lowercased)
        guard lowercased.contains("schema version mismatch")
            || lowercased.contains("schema skew")
            || (lowercased.contains("binary expects v") && lowercased.contains("database is at v"))
            || reportedDirection != nil
        else { return nil }
        let databaseVersion = version(afterAny: [
            "database is at v",
            "database (v"
        ], in: lowercased)
        let binaryVersion = version(afterAny: [
            "binary expects v",
            "binary knows up to v",
            "binary (v"
        ], in: lowercased)
        return BeadsSchemaSkew(
            databaseVersion: databaseVersion,
            binaryVersion: binaryVersion,
            reportedDirection: reportedDirection
        )
    }

    private static func version(afterAny markers: [String], in lowercasedText: String) -> Int? {
        for marker in markers {
            guard let markerRange = lowercasedText.range(of: marker) else { continue }
            let digits = lowercasedText[markerRange.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { return Int(digits) }
        }
        return nil
    }

    private static func reportedDirection(in lowercasedText: String) -> BeadsSchemaSkewDirection? {
        if lowercasedText.contains("migrations ahead")
            || lowercasedText.contains("database is ahead")
            || (lowercasedText.contains("database (")
                && lowercasedText.contains(" is ahead of binary")) {
            return .databaseAhead
        }
        if lowercasedText.contains("database is behind")
            || (lowercasedText.contains("database (")
                && lowercasedText.contains(" is behind binary"))
            || lowercasedText.contains("read-only open cannot migrate") {
            return .databaseBehind
        }
        return nil
    }
}

enum BeadsTrackerRecoveryGuide {
    static let url = URL(
        string: "https://github.com/gastownhall/beads/blob/v1.2.2/docs/RECOVERY-1.2.1.md"
    )!
}

/// Why Beadazzle will not migrate a tracker without asking first.
///
/// `bd` itself refuses to migrate a remote-backed database in place: migrating two
/// clones independently forks the schema so `bd dolt pull` can no longer merge them,
/// and the break is silent and unrecoverable. Only the single designated migrator
/// should proceed, so that decision stays with the user.
enum BeadsTrackerMigrationConfirmationReason: Equatable, Sendable {
    case remoteBackedTracker
    case sharedDatabaseMode
    /// Beadazzle could not determine whether this tracker has a remote — usually because
    /// the project failed to open far enough to read its remote list.
    case unverifiedRemoteState

    var explanation: String {
        switch self {
        case .remoteBackedTracker:
            return """
            This tracker has a Dolt remote. Upgrading more than one clone independently \
            forks the schema so `bd dolt pull` can no longer merge them. Only continue if \
            you are the person designated to upgrade it, then push the upgraded schema.
            """
        case .sharedDatabaseMode:
            return """
            This project uses a shared Beads database. Upgrading it affects everyone \
            connected to it, so Beadazzle will not start the upgrade on its own.
            """
        case .unverifiedRemoteState:
            return """
            Beadazzle could not check whether this tracker has a Dolt remote. If it does, \
            upgrading more than one clone independently forks the schema so `bd dolt pull` \
            can no longer merge them. Continue if this tracker is local, or if you are the \
            person designated to upgrade it.
            """
        }
    }
}

/// Tracks the one-time `bd` schema upgrade for the open project.
enum BeadsTrackerMigrationState: Equatable, Sendable {
    /// No migration is known to be needed.
    case notNeeded
    /// A migration is required and Beadazzle is waiting for the user to confirm it.
    case awaitingConfirmation(BeadsSchemaSkew, reason: BeadsTrackerMigrationConfirmationReason)
    /// A migration is required and safe to start without asking.
    case ready(BeadsSchemaSkew)
    /// `bd migrate` is running.
    case migrating
    /// The migration failed. `requiresDesignatedMigrator` is true when `bd` refused
    /// because the database is remote-backed and needs an explicit override.
    case failed(message: String, requiresDesignatedMigrator: Bool)
    /// The database is ahead in the one exact form covered by the pinned recovery guide.
    /// The user must review preflight, backup, and publication guidance before any repair.
    case recoveryAvailable(BeadsSchemaSkew)
    /// The mismatch cannot be repaired automatically. No schema write is permitted.
    case recoveryBlocked(BeadsSchemaSkew, guidance: String)

    var isPending: Bool {
        switch self {
        case .notNeeded: return false
        case .awaitingConfirmation, .ready, .migrating, .failed,
             .recoveryAvailable, .recoveryBlocked:
            return true
        }
    }

    var isMigrating: Bool {
        self == .migrating
    }

    /// True while the tracker cannot accept writes, because `bd` cannot read it
    /// consistently until the schema matches the installed binary.
    var blocksWrites: Bool {
        isPending
    }

    var skew: BeadsSchemaSkew? {
        switch self {
        case .awaitingConfirmation(let skew, _), .ready(let skew),
             .recoveryAvailable(let skew), .recoveryBlocked(let skew, _):
            return skew
        case .notNeeded, .migrating, .failed:
            return nil
        }
    }

    var canReviewRecovery: Bool {
        if case .recoveryAvailable = self { return true }
        return false
    }

    var usesUpwardMigration: Bool {
        switch self {
        case .awaitingConfirmation, .ready, .migrating, .failed:
            true
        case .notNeeded, .recoveryAvailable, .recoveryBlocked:
            false
        }
    }

    var schemaResolution: BeadsSchemaSkewResolution? {
        switch self {
        case .awaitingConfirmation(let skew, _), .ready(let skew),
             .recoveryAvailable(let skew), .recoveryBlocked(let skew, _):
            skew.resolution
        case .migrating, .failed:
            .upwardMigration
        case .notNeeded:
            nil
        }
    }

    var isRecoveryBlocked: Bool {
        if case .recoveryBlocked = self { return true }
        return false
    }
}
