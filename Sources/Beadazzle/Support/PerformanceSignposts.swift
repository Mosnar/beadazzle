import OSLog

/// Centralized `OSSignposter` instances for measuring the read and query paths
/// with Instruments (Points of Interest / os_signpost). Categories map to the
/// two hot paths: loading a project into an immutable index, and the
/// filter/sort/row-build query pipeline that feeds the issue list.
///
/// Usage: `PerformanceSignposts.query.withIntervalSignpost("Sort") { ... }`.
/// Intervals compile down to near-zero overhead when Instruments is not
/// attached, so they are safe to leave in release builds.
enum PerformanceSignposts {
    static let subsystem = "com.beadazzle.performance"

    /// Snapshot parse + immutable index construction in `BeadProjectLoader`.
    static let load = OSSignposter(subsystem: subsystem, category: "ProjectLoad")

    /// Filter / sort / row-build pipeline in `BeadIssueListQuery`.
    static let query = OSSignposter(subsystem: subsystem, category: "Query")
}
