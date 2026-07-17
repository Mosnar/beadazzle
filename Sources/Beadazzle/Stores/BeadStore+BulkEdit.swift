import Foundation

extension BeadStore {
    func makeBulkEditRequest(
        issueIDs: Set<String>,
        target: BulkEditTarget
    ) -> BulkEditRequest? {
        guard let projectURL else { return nil }
        let issues = issueIDs.sorted().compactMap { issue(with: $0) }
        guard !issues.isEmpty else { return nil }
        let validIssueIDs = issues.map(\.id)

        let payload: BulkEditPayload
        switch target {
        case .addLabels:
            let managedDimensions = stateDimensionsManagedForLabelEditing(issueIDs: validIssueIDs)
            payload = .addLabels(BulkAddLabelsContext(
                issues: issues,
                availableLabels: availableLabels,
                managedDimensions: managedDimensions
            ))

        case .setProperty(let dimension):
            let catalog = stateValueCatalog(for: dimension)
            let currentValues = issues.map { BeadStateLabel.value(of: dimension, in: $0.labels) }
            var valueCounts: [String: Int] = [:]
            for value in currentValues.compactMap({ $0 }) {
                valueCounts[value, default: 0] += 1
            }
            let distinctValues = Set(currentValues)
            let currentSummary: String
            if distinctValues.count != 1 {
                currentSummary = "Mixed"
            } else if let value = distinctValues.first ?? nil {
                currentSummary = stateValueDisplayName(for: value, in: dimension)
            } else {
                currentSummary = "None"
            }
            let currentValueSet = Set(currentValues.compactMap { $0 })
            let candidateValues = catalog.active + catalog.archived.filter {
                currentValueSet.contains($0.value)
            }
            payload = .setProperty(
                dimension: dimension,
                context: BulkSetPropertyContext(
                    issueCount: issues.count,
                    displayName: stateDimensionDisplayName(for: dimension),
                    currentSummary: currentSummary,
                    catalog: catalog,
                    candidateValues: candidateValues,
                    currentValueCounts: valueCounts
                )
            )
        }

        return BulkEditRequest(
            projectURL: projectURL,
            issueIDs: validIssueIDs,
            payload: payload
        )
    }
}
