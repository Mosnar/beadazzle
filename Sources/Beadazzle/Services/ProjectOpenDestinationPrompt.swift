import AppKit

struct ProjectOpenDestinationPromptRequest: Equatable, Sendable {
    let projectName: String
    let currentProjectName: String
}

enum ProjectOpenDestinationPromptChoice: Equatable, Sendable {
    case currentWindow
    case newWindow
    case cancel

    var destination: BeadProjectOpenDestination? {
        switch self {
        case .currentWindow:
            .currentWindow
        case .newWindow:
            .newWindow
        case .cancel:
            nil
        }
    }

    var preference: BeadProjectOpenDestinationPreference? {
        switch self {
        case .currentWindow:
            .currentWindow
        case .newWindow:
            .newWindow
        case .cancel:
            nil
        }
    }
}

struct ProjectOpenDestinationPromptResponse: Equatable, Sendable {
    let choice: ProjectOpenDestinationPromptChoice
    let remembersChoice: Bool
}

@MainActor
protocol ProjectOpenDestinationPrompting {
    func prompt(
        _ request: ProjectOpenDestinationPromptRequest,
        attachedTo window: NSWindow?
    ) async -> ProjectOpenDestinationPromptResponse
}

/// SwiftUI's alert API cannot include the native macOS suppression checkbox. Keep that
/// narrow platform edge here while the routing decision and persisted preference remain
/// owned by the workspace registry and `BeadStore`.
@MainActor
struct AppKitProjectOpenDestinationPrompter: ProjectOpenDestinationPrompting {
    func prompt(
        _ request: ProjectOpenDestinationPromptRequest,
        attachedTo window: NSWindow?
    ) async -> ProjectOpenDestinationPromptResponse {
        let alert = makeAlert(for: request)
        let modalResponse: NSApplication.ModalResponse

        if let window {
            modalResponse = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        } else {
            // A workspace normally reports its NSWindow before it can initiate this
            // action. Retain a functional fallback for unusually early menu activation.
            modalResponse = alert.runModal()
        }

        return response(for: modalResponse, from: alert)
    }

    func makeAlert(for request: ProjectOpenDestinationPromptRequest) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open \u{201c}\(request.projectName)\u{201d} in a New Window?"
        alert.informativeText = "Keep \u{201c}\(request.currentProjectName)\u{201d} open, or replace it in this window. You can change a remembered choice later in Settings."
        alert.addButton(withTitle: "Open in New Window")
        alert.addButton(withTitle: "Open in This Window")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"
        return alert
    }

    func response(
        for modalResponse: NSApplication.ModalResponse,
        from alert: NSAlert
    ) -> ProjectOpenDestinationPromptResponse {
        let choice: ProjectOpenDestinationPromptChoice = switch modalResponse {
        case .alertFirstButtonReturn:
            .newWindow
        case .alertSecondButtonReturn:
            .currentWindow
        default:
            .cancel
        }
        return ProjectOpenDestinationPromptResponse(
            choice: choice,
            remembersChoice: alert.suppressionButton?.state == .on
        )
    }
}
