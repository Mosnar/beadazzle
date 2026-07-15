struct ProjectHealthPresentation: Equatable, Sendable {
    let attentionChecks: [ProjectPreflightHealth.Check]
    let otherChecks: [ProjectPreflightHealth.Check]
    let summaryBadgeStatus: ProjectPreflightHealth.Status?

    init(preflight: ProjectPreflightHealth) {
        attentionChecks = preflight.checks.filter(\.status.requiresAttention)
        otherChecks = preflight.checks.filter { !$0.status.requiresAttention }
        summaryBadgeStatus = preflight.status.requiresAttention ? preflight.status : nil
    }

    var checksDisclosureTitle: String {
        attentionChecks.isEmpty ? "View All Checks" : "Other Checks"
    }
}

extension ProjectPreflightHealth.Status {
    var requiresAttention: Bool {
        switch self {
        case .warning, .blocked, .checking:
            true
        case .ready, .info:
            false
        }
    }
}
