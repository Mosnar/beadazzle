import Foundation
import SwiftUI

private struct FolderAutomationExecution: Sendable {
    let id: UUID
    let folderID: UUID
    let folderName: String
    let projectURL: URL
    let automation: BeadFolderAutomation
    let issueIDs: [String]
    let retryWork: FolderAutomationRetryWork?

    init(
        id: UUID = UUID(),
        folderID: UUID,
        folderName: String,
        projectURL: URL,
        automation: BeadFolderAutomation,
        issueIDs: [String],
        retryWork: FolderAutomationRetryWork?
    ) {
        self.id = id
        self.folderID = folderID
        self.folderName = folderName
        self.projectURL = projectURL
        self.automation = automation
        self.issueIDs = issueIDs
        self.retryWork = retryWork
    }
}

private struct FolderAutomationRetryWork: Sendable {
    var labelIssueIDs: [String] = []
    var statusIssueIDs: [String] = []
    var propertyIssueIDs: [String: [String]] = [:]

    var allIssueIDs: [String] {
        Array(Set(
            labelIssueIDs
                + statusIssueIDs
                + propertyIssueIDs.values.flatMap { $0 }
        )).sorted()
    }

    var isEmpty: Bool {
        labelIssueIDs.isEmpty
            && statusIssueIDs.isEmpty
            && propertyIssueIDs.values.allSatisfy(\.isEmpty)
    }

    mutating func normalize() {
        labelIssueIDs = Array(Set(labelIssueIDs)).sorted()
        statusIssueIDs = Array(Set(statusIssueIDs)).sorted()
        propertyIssueIDs = propertyIssueIDs.mapValues {
            Array(Set($0)).sorted()
        }
    }
}

extension BeadStore {
    private static let folderAutomationBatchSize = 250
    private static let folderAutomationPropertyBatchSize = 25

    func scheduleFolderAutomation(
        folderID: UUID,
        folderName: String,
        automation rawAutomation: BeadFolderAutomation,
        issueIDs: [String]
    ) {
        guard let projectURL, !issueIDs.isEmpty else { return }
        let validation = folderAutomationValidation(rawAutomation)
        guard validation.isValid else {
            reportInvalidFolderAutomation(
                folderName: folderName,
                message: validation.message
            )
            return
        }
        guard !validation.automation.isEmpty else { return }

        enqueueFolderAutomation(FolderAutomationExecution(
            folderID: folderID,
            folderName: folderName,
            projectURL: projectURL,
            automation: validation.automation,
            issueIDs: issueIDs,
            retryWork: nil
        ))
    }

    func applyFolderAutomationNow(folderID: UUID) {
        guard let view = savedViews.first(where: { $0.id == folderID }),
              let folder = view.folder
        else { return }
        scheduleFolderAutomation(
            folderID: folderID,
            folderName: view.name,
            automation: folder.automation,
            issueIDs: folder.orderedIssueIDs
        )
    }

    func cancelCurrentFolderAutomation() {
        guard let progress = folderAutomationProgress, !progress.isCancelling else { return }
        mutations.cancelledFolderAutomationIDs.insert(progress.id)
        folderAutomationProgress = BeadFolderAutomationProgress(
            id: progress.id,
            folderName: progress.folderName,
            completedUnitCount: progress.completedUnitCount,
            totalUnitCount: progress.totalUnitCount,
            detail: "Cancelling after the current command…",
            isCancelling: true
        )
    }

    private func enqueueFolderAutomation(_ execution: FolderAutomationExecution) {
        let previous = mutations.folderAutomationTail
        mutations.folderAutomationTail = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await self.runFolderAutomation(execution)
        }
    }

    private func runFolderAutomation(_ execution: FolderAutomationExecution) async {
        defer {
            mutations.cancelledFolderAutomationIDs.remove(execution.id)
            if folderAutomationProgress?.id == execution.id {
                folderAutomationProgress = nil
            }
        }

        guard folderAutomationCanContinue(execution) else { return }
        let validation = folderAutomationValidation(execution.automation)
        guard validation.isValid else {
            reportInvalidFolderAutomation(
                folderName: execution.folderName,
                message: validation.message
            )
            return
        }

        let initialIDs = execution.retryWork?.allIssueIDs ?? execution.issueIDs
        let availableIDs = await eligibleFolderIssueIDsResponsively(
            initialIDs,
            execution: execution
        )
        guard folderAutomationCanContinue(execution), !availableIDs.isEmpty else {
            if folderAutomationWasCancelled(execution) {
                finishCancelledFolderAutomation(execution, completed: 0, total: 0)
            }
            return
        }

        let availableIDSet = Set(availableIDs)
        let automation = validation.automation
        let labelIDs = execution.retryWork.map {
            $0.labelIssueIDs.filter(availableIDSet.contains)
        } ?? availableIDs
        let statusIDs = execution.retryWork.map {
            $0.statusIssueIDs.filter(availableIDSet.contains)
        } ?? availableIDs
        let propertyUnitCount: Int
        if let retryWork = execution.retryWork {
            propertyUnitCount = automation.propertyAssignments.reduce(into: 0) { count, assignment in
                count += retryWork.propertyIssueIDs[assignment.dimension, default: []]
                    .lazy
                    .filter(availableIDSet.contains)
                    .count
            }
        } else {
            propertyUnitCount = availableIDs.count * automation.propertyAssignments.count
        }
        let totalUnitCount =
            ((!automation.labelsToAdd.isEmpty || !automation.labelsToRemove.isEmpty)
                ? labelIDs.count
                : 0)
            + (automation.status == nil ? 0 : statusIDs.count)
            + propertyUnitCount
        guard totalUnitCount > 0 else { return }

        var completedUnitCount = 0
        var failures = BulkMutationFailureCollection()
        var retryWork = FolderAutomationRetryWork()
        var skippedStatusCount = 0
        var rejectedActions: [String] = []
        beginFolderAutomationProgress(
            execution,
            total: totalUnitCount,
            detail: "Preparing actions…"
        )

        if !labelIDs.isEmpty,
           !automation.labelsToAdd.isEmpty || !automation.labelsToRemove.isEmpty {
            var startIndex = 0
            while startIndex < labelIDs.count {
                guard folderAutomationCanContinue(execution) else {
                    if folderAutomationWasCancelled(execution) {
                        finishCancelledFolderAutomation(
                            execution,
                            completed: completedUnitCount,
                            total: totalUnitCount
                        )
                    }
                    return
                }
                let endIndex = min(
                    labelIDs.count,
                    startIndex + Self.folderAutomationBatchSize
                )
                let chunk = Array(labelIDs[startIndex..<endIndex])
                updateFolderAutomationProgress(
                    execution,
                    completed: completedUnitCount,
                    total: totalUnitCount,
                    detail: "Updating labels…"
                )
                let result = await updateLabels(
                    issueIDs: chunk,
                    adding: automation.labelsToAdd,
                    removing: automation.labelsToRemove,
                    expectedProjectURL: execution.projectURL,
                    reportsFeedback: false,
                    cancellationRequested: { [weak self] in
                        self?.folderAutomationWasCancelled(execution) == true
                    },
                    progress: { [weak self] progress in
                        self?.updateFolderAutomationProgress(
                            execution,
                            completed: completedUnitCount + progress.completedCount,
                            total: totalUnitCount,
                            detail: "Updating labels…"
                        )
                    }
                )
                failures.merge(result)
                retryWork.labelIssueIDs.append(contentsOf: result.failedIssueIDs)

                switch result.outcome {
                case .completed:
                    completedUnitCount += chunk.count
                case .cancelled:
                    completedUnitCount += result.progress.completedCount
                    finishCancelledFolderAutomation(
                        execution,
                        completed: completedUnitCount,
                        total: totalUnitCount
                    )
                    return
                case .superseded:
                    return
                case .rejected:
                    rejectedActions.append("Update Labels")
                    completedUnitCount += chunk.count
                    startIndex = labelIDs.count
                    continue
                }
                startIndex = endIndex
            }
        }

        if let status = automation.status, !statusIDs.isEmpty {
            var startIndex = 0
            while startIndex < statusIDs.count {
                guard folderAutomationCanContinue(execution) else {
                    if folderAutomationWasCancelled(execution) {
                        finishCancelledFolderAutomation(
                            execution,
                            completed: completedUnitCount,
                            total: totalUnitCount
                        )
                    }
                    return
                }
                let endIndex = min(
                    statusIDs.count,
                    startIndex + Self.folderAutomationBatchSize
                )
                let chunk = Array(statusIDs[startIndex..<endIndex])
                let safeStatusIDs = chunk.filter {
                    statusChangeConfirmation(forSetting: status, on: [$0]) == .proceed
                }
                skippedStatusCount += chunk.count - safeStatusIDs.count
                updateFolderAutomationProgress(
                    execution,
                    completed: completedUnitCount,
                    total: totalUnitCount,
                    detail: "Updating status…"
                )
                guard !safeStatusIDs.isEmpty else {
                    completedUnitCount += chunk.count
                    startIndex = endIndex
                    continue
                }

                let result = await bulkSetResult(
                    issueIDs: safeStatusIDs,
                    status: status,
                    expectedProjectURL: execution.projectURL,
                    reportsFeedback: false
                )
                failures.merge(result)
                retryWork.statusIssueIDs.append(contentsOf: result.failedIssueIDs)

                switch result.outcome {
                case .completed:
                    completedUnitCount += chunk.count
                case .cancelled:
                    completedUnitCount += result.progress.completedCount
                    finishCancelledFolderAutomation(
                        execution,
                        completed: completedUnitCount,
                        total: totalUnitCount
                    )
                    return
                case .superseded:
                    return
                case .rejected:
                    rejectedActions.append("Update Status")
                    completedUnitCount += chunk.count
                    startIndex = statusIDs.count
                    continue
                }
                startIndex = endIndex
            }
        }

        for assignment in automation.propertyAssignments {
            guard folderAutomationCanContinue(execution) else {
                if folderAutomationWasCancelled(execution) {
                    finishCancelledFolderAutomation(
                        execution,
                        completed: completedUnitCount,
                        total: totalUnitCount
                    )
                }
                return
            }
            let propertyIDs = execution.retryWork.map {
                $0.propertyIssueIDs[assignment.dimension, default: []]
                    .filter(availableIDSet.contains)
            } ?? availableIDs
            var startIndex = 0
            while startIndex < propertyIDs.count {
                guard folderAutomationCanContinue(execution) else {
                    if folderAutomationWasCancelled(execution) {
                        finishCancelledFolderAutomation(
                            execution,
                            completed: completedUnitCount,
                            total: totalUnitCount
                        )
                    }
                    return
                }
                let endIndex = min(
                    propertyIDs.count,
                    startIndex + Self.folderAutomationPropertyBatchSize
                )
                let chunk = Array(propertyIDs[startIndex..<endIndex])
                let actionName = "Update \(stateDimensionDisplayName(for: assignment.dimension))"
                updateFolderAutomationProgress(
                    execution,
                    completed: completedUnitCount,
                    total: totalUnitCount,
                    detail: "\(actionName)…"
                )
                let result = await bulkSetState(
                    issueIDs: chunk,
                    dimension: assignment.dimension,
                    value: assignment.value,
                    reason: "Folder automation: \(execution.folderName)",
                    expectedProjectURL: execution.projectURL,
                    reportsFeedback: false,
                    cancellationRequested: { [weak self] in
                        self?.folderAutomationWasCancelled(execution) == true
                    },
                    progress: { [weak self] progress in
                        self?.updateFolderAutomationProgress(
                            execution,
                            completed: completedUnitCount + progress.completedCount,
                            total: totalUnitCount,
                            detail: "\(actionName)…"
                        )
                    }
                )
                failures.merge(result)
                retryWork.propertyIssueIDs[assignment.dimension, default: []]
                    .append(contentsOf: result.failedIssueIDs)

                switch result.outcome {
                case .completed:
                    completedUnitCount += chunk.count
                case .cancelled:
                    completedUnitCount += result.progress.completedCount
                    finishCancelledFolderAutomation(
                        execution,
                        completed: completedUnitCount,
                        total: totalUnitCount
                    )
                    return
                case .superseded:
                    return
                case .rejected:
                    rejectedActions.append(actionName)
                    completedUnitCount += chunk.count
                    startIndex = propertyIDs.count
                    continue
                }
                startIndex = endIndex
            }
        }

        guard folderAutomationCanContinue(execution) else {
            if folderAutomationWasCancelled(execution) {
                finishCancelledFolderAutomation(
                    execution,
                    completed: completedUnitCount,
                    total: totalUnitCount
                )
            }
            return
        }

        retryWork.normalize()
        if !failures.isEmpty, !retryWork.isEmpty {
            let baseline = retryBaseline(for: retryWork.allIssueIDs)
            reportBulkMutationFailure(
                failures,
                title: "Couldn't finish \(execution.folderName) automation",
                retry: { [weak self] in
                    guard let self,
                          self.retryBaselineHolds(baseline),
                          self.folderAutomationRetryIsCurrent(execution)
                    else { return }
                    self.enqueueFolderAutomation(FolderAutomationExecution(
                        folderID: execution.folderID,
                        folderName: execution.folderName,
                        projectURL: execution.projectURL,
                        automation: execution.automation,
                        issueIDs: execution.issueIDs,
                        retryWork: retryWork
                    ))
                }
            )
        }

        let summary = folderAutomationCompletionSummary(
            execution,
            availableIssueCount: availableIDs.count,
            failedIssueCount: retryWork.allIssueIDs.count,
            skippedStatusCount: skippedStatusCount,
            rejectedActions: Array(Set(rejectedActions)).sorted()
        )
        showFolderAutomationSummary(summary)
        announceCompletion(summary)
    }

    private func eligibleFolderIssueIDsResponsively(
        _ issueIDs: [String],
        execution: FolderAutomationExecution
    ) async -> [String] {
        var seen: Set<String> = []
        var eligibleIDs: [String] = []
        eligibleIDs.reserveCapacity(issueIDs.count)
        for (index, rawID) in issueIDs.enumerated() {
            if index > 0, index.isMultiple(of: Self.folderAutomationBatchSize) {
                await Task.yield()
                guard folderAutomationCanContinue(execution) else { return eligibleIDs }
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  seen.insert(id).inserted,
                  self.index.isUserFacingIssueID(id),
                  issue(with: id)?.isSystemRecord != true
            else { continue }
            eligibleIDs.append(id)
        }
        return eligibleIDs
    }

    private func folderAutomationCanContinue(_ execution: FolderAutomationExecution) -> Bool {
        projectURL == execution.projectURL
            && !Task.isCancelled
            && !folderAutomationWasCancelled(execution)
    }

    private func folderAutomationWasCancelled(_ execution: FolderAutomationExecution) -> Bool {
        mutations.cancelledFolderAutomationIDs.contains(execution.id)
    }

    private func folderAutomationRetryIsCurrent(
        _ execution: FolderAutomationExecution
    ) -> Bool {
        guard projectURL == execution.projectURL,
              let view = savedViews.first(where: { $0.id == execution.folderID }),
              view.name == execution.folderName,
              let folder = view.folder
        else { return false }
        let validation = folderAutomationValidation(folder.automation)
        return validation.isValid && validation.automation == execution.automation
    }

    private func beginFolderAutomationProgress(
        _ execution: FolderAutomationExecution,
        total: Int,
        detail: String
    ) {
        folderAutomationSummary = nil
        updateFolderAutomationProgress(
            execution,
            completed: 0,
            total: total,
            detail: detail
        )
    }

    private func updateFolderAutomationProgress(
        _ execution: FolderAutomationExecution,
        completed: Int,
        total: Int,
        detail: String
    ) {
        let isCancelling = folderAutomationWasCancelled(execution)
        folderAutomationProgress = BeadFolderAutomationProgress(
            id: execution.id,
            folderName: execution.folderName,
            completedUnitCount: min(completed, total),
            totalUnitCount: total,
            detail: isCancelling ? "Cancelling after the current command…" : detail,
            isCancelling: isCancelling
        )
    }

    private func finishCancelledFolderAutomation(
        _ execution: FolderAutomationExecution,
        completed: Int,
        total: Int
    ) {
        let summary: String
        if total > 0 {
            summary = "Cancelled \(execution.folderName) automation after \(completed.formatted()) of \(total.formatted()) actions."
        } else {
            summary = "Cancelled \(execution.folderName) automation."
        }
        showFolderAutomationSummary(summary)
        announceCompletion(summary)
    }

    private func reportInvalidFolderAutomation(
        folderName: String,
        message: String?
    ) {
        let detail = message ?? "The automation configuration is no longer valid."
        let summary = "Couldn't run \(folderName) automation. \(detail)"
        lastError = detail
        showFolderAutomationSummary(summary)
        announceCompletion(summary)
    }

    private func folderAutomationCompletionSummary(
        _ execution: FolderAutomationExecution,
        availableIssueCount: Int,
        failedIssueCount: Int,
        skippedStatusCount: Int,
        rejectedActions: [String]
    ) -> String {
        var details: [String] = []
        if failedIssueCount > 0 {
            details.append(
                "\(failedIssueCount.formatted()) bead\(failedIssueCount == 1 ? "" : "s") need retry"
            )
        }
        if skippedStatusCount > 0 {
            details.append(
                "status skipped for \(skippedStatusCount.formatted()) bead\(skippedStatusCount == 1 ? "" : "s") needing confirmation"
            )
        }
        if !rejectedActions.isEmpty {
            details.append("skipped \(rejectedActions.joined(separator: ", "))")
        }
        if details.isEmpty {
            return "Finished \(execution.folderName) automation for \(availableIssueCount.formatted()) bead\(availableIssueCount == 1 ? "" : "s")."
        }
        return "Finished \(execution.folderName) automation; \(details.joined(separator: "; "))."
    }

    private func showFolderAutomationSummary(_ summary: String) {
        folderAutomationSummary = summary
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard self?.folderAutomationSummary == summary else { return }
            self?.folderAutomationSummary = nil
        }
    }

    func waitForPendingFolderAutomation() async {
        await mutations.folderAutomationTail?.value
    }
}
