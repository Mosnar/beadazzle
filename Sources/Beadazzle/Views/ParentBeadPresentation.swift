struct ParentBeadPresentation {
    let issue: BeadIssue

    var id: String {
        issue.id
    }

    var detailText: String {
        guard let title = issue.title.nilIfBlank else { return issue.id }
        return "\(issue.id): \(title)"
    }

    var helpText: String {
        "Open parent bead \(detailText)"
    }

    var accessibilityLabel: String {
        "Parent bead"
    }

    var accessibilityValue: String {
        detailText
    }
}
