import Foundation

struct IssueTextSectionVisibilityOverrides: Equatable, Sendable {
    private(set) var revealed: Set<IssueTextSection> = []
    private(set) var hidden: Set<IssueTextSection> = []

    mutating func reveal(_ section: IssueTextSection) {
        hidden.remove(section)
        revealed.insert(section)
    }

    mutating func hide(_ section: IssueTextSection) {
        revealed.remove(section)
        hidden.insert(section)
    }
}

struct IssueTextSectionLayout: Equatable, Sendable {
    let visible: [IssueTextSection]
    let hidden: [IssueTextSection]
}

enum IssueTextSectionPresentationPolicy {
    static func effectivePreferences(
        app: IssueTextSectionPreferences,
        project: ProjectIssueTextSectionOverrides
    ) -> IssueTextSectionPreferences {
        let app = app.normalized()
        let project = project.normalized()
        var suggestions = app.suggestions
        for (type, sections) in project.suggestionsByType {
            suggestions.setSections(Set(sections), for: type)
        }
        return IssueTextSectionPreferences(
            visibilityMode: project.visibilityMode ?? app.visibilityMode,
            order: project.order ?? app.order,
            suggestions: suggestions
        ).normalized()
    }

    static func canHide(_ section: IssueTextSection, in draft: IssueDraft) -> Bool {
        !section.hasContent(in: draft)
    }

    static func shouldRevealAfterEditing(existingText: String, updatedText: String) -> Bool {
        IssueTextSection.hasContent(existingText) && !IssueTextSection.hasContent(updatedText)
    }

    static func editorLayout(
        draft: IssueDraft,
        preferences: IssueTextSectionPreferences,
        explicitlyRevealed: Set<IssueTextSection>,
        explicitlyHidden: Set<IssueTextSection>
    ) -> IssueTextSectionLayout {
        let preferences = preferences.normalized()
        let suggested: Set<IssueTextSection>
        switch preferences.visibilityMode {
        case .suggestedForType:
            suggested = preferences.suggestions.sections(for: draft.issueType)
        case .descriptionOnly:
            suggested = [.description]
        case .allSections:
            suggested = Set(IssueTextSection.allCases)
        }
        let populated = populatedSections(in: draft)
        let visible = suggested
            .union(explicitlyRevealed)
            .subtracting(explicitlyHidden)
            .union(populated)
        return IssueTextSectionLayout(
            visible: preferences.order.filter(visible.contains),
            hidden: preferences.order.filter { !visible.contains($0) }
        )
    }

    private static func populatedSections(in draft: IssueDraft) -> Set<IssueTextSection> {
        Set(IssueTextSection.allCases.filter { $0.hasContent(in: draft) })
    }
}
