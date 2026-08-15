import Foundation

/// A pending Beads schema migration, detected from `bd`'s own refusal to open an
/// out-of-date database read-only.
///
/// `bd` bumps its database schema between releases and migrates on the first
/// *write*-mode open. Beadazzle reads through `bd --readonly`, and a read-only open
/// cannot migrate, so every read fails until something migrates the tracker. The
/// failure text is the only signal `bd` gives us, so it is parsed here rather than
/// probed for separately — the commands Beadazzle already runs on open surface it.
struct BeadsSchemaSkew: Equatable, Sendable {
    /// The schema version currently stored in the tracker database.
    var databaseVersion: Int?
    /// The schema version the installed `bd` binary expects.
    var binaryVersion: Int?

    var versionSummary: String? {
        guard let databaseVersion, let binaryVersion else { return nil }
        return "Database is at v\(databaseVersion); bd expects v\(binaryVersion)."
    }

    /// Matches `bd`'s read-only schema-mismatch refusal, e.g.
    /// `schema version mismatch: database is at v53, binary expects v65, and the
    /// read-only open cannot migrate it; run any bd write command in that workspace
    /// to migrate, or set BD_IGNORE_SCHEMA_SKEW=1 to read anyway`.
    ///
    /// The version numbers are parsed when present but are not required — the
    /// mismatch phrase alone is enough to know the tracker needs migrating.
    static func detect(in text: String) -> BeadsSchemaSkew? {
        let lowercased = text.lowercased()
        guard lowercased.contains("schema version mismatch")
            || lowercased.contains("schema skew")
            || (lowercased.contains("binary expects v") && lowercased.contains("database is at v"))
        else { return nil }
        return BeadsSchemaSkew(
            databaseVersion: version(after: "database is at v", in: lowercased),
            binaryVersion: version(after: "binary expects v", in: lowercased)
        )
    }

    private static func version(after marker: String, in lowercasedText: String) -> Int? {
        guard let markerRange = lowercasedText.range(of: marker) else { return nil }
        let digits = lowercasedText[markerRange.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
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

    var isPending: Bool {
        switch self {
        case .notNeeded: return false
        case .awaitingConfirmation, .ready, .migrating, .failed: return true
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
        case .awaitingConfirmation(let skew, _), .ready(let skew):
            return skew
        case .notNeeded, .migrating, .failed:
            return nil
        }
    }
}
