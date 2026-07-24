import Foundation

struct BeadFolderPropertyAssignment: Identifiable, Hashable, Codable, Sendable {
    var dimension: String
    var value: String

    var id: String { dimension }
}

struct BeadFolderAutomation: Hashable, Codable, Sendable {
    var labelsToAdd: [String] = []
    var labelsToRemove: [String] = []
    var status: String?
    var propertyAssignments: [BeadFolderPropertyAssignment] = []

    var isEmpty: Bool {
        labelsToAdd.isEmpty
            && labelsToRemove.isEmpty
            && status == nil
            && propertyAssignments.isEmpty
    }

    var normalized: Self {
        let labelsToAdd = Self.normalizedLabels(labelsToAdd)
        let addedLabelSet = Set(labelsToAdd)
        let labelsToRemove = Self.normalizedLabels(labelsToRemove).filter {
            !addedLabelSet.contains($0)
        }

        var seenDimensions: Set<String> = []
        let propertyAssignments: [BeadFolderPropertyAssignment] = propertyAssignments.compactMap { assignment in
            guard let dimension = BeadStateLabel.normalizedDimensionInput(assignment.dimension),
                  let value = BeadStateLabel.normalizedValueInput(assignment.value),
                  seenDimensions.insert(dimension).inserted
            else {
                return nil
            }
            return BeadFolderPropertyAssignment(dimension: dimension, value: value)
        }

        return Self(
            labelsToAdd: labelsToAdd,
            labelsToRemove: labelsToRemove,
            status: status?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            propertyAssignments: propertyAssignments
        )
    }

    private static func normalizedLabels(_ labels: [String]) -> [String] {
        let parsed = IssueDraft.normalizedLabels(IssueDraft.normalizedLabelText(labels))
        var seen: Set<String> = []
        return parsed.filter { seen.insert($0).inserted }
    }
}

struct BeadFolderAutomationDraft: Equatable, Sendable {
    var labelsToAdd: [String]?
    var labelsToRemove: [String]?
    var status: String?
    var propertyAssignments: [BeadFolderPropertyAssignment]

    init(automation: BeadFolderAutomation = BeadFolderAutomation()) {
        labelsToAdd = automation.labelsToAdd.isEmpty ? nil : automation.labelsToAdd
        labelsToRemove = automation.labelsToRemove.isEmpty ? nil : automation.labelsToRemove
        status = automation.status
        propertyAssignments = automation.propertyAssignments
    }

    var automation: BeadFolderAutomation {
        BeadFolderAutomation(
            labelsToAdd: labelsToAdd ?? [],
            labelsToRemove: labelsToRemove ?? [],
            status: status,
            propertyAssignments: propertyAssignments
        )
    }

    var hasConfiguredAction: Bool {
        labelsToAdd != nil
            || labelsToRemove != nil
            || status != nil
            || !propertyAssignments.isEmpty
    }

    var incompleteActionMessage: String? {
        if labelsToAdd?.isEmpty == true {
            return "Choose at least one label to add."
        }
        if labelsToRemove?.isEmpty == true {
            return "Choose at least one label to remove."
        }
        if propertyAssignments.contains(where: { $0.value.nilIfBlank == nil }) {
            return "Choose a value for every property action."
        }
        return nil
    }
}

struct BeadFolderAutomationValidation: Equatable, Sendable {
    let automation: BeadFolderAutomation
    let message: String?

    var isValid: Bool { message == nil }
}

struct BeadFolderAutomationProgress: Equatable, Identifiable, Sendable {
    let id: UUID
    let folderName: String
    let completedUnitCount: Int
    let totalUnitCount: Int
    let detail: String
    let isCancelling: Bool

    var fractionCompleted: Double {
        guard totalUnitCount > 0 else { return 0 }
        return min(1, Double(completedUnitCount) / Double(totalUnitCount))
    }
}
