import AppKit
import XCTest
@testable import Beadazzle

@MainActor
final class ProjectOpenDestinationPromptTests: XCTestCase {
    func testNativeAlertContract() {
        let prompter = AppKitProjectOpenDestinationPrompter()
        let alert = prompter.makeAlert(
            for: ProjectOpenDestinationPromptRequest(
                projectName: "Beta",
                currentProjectName: "Alpha"
            )
        )

        XCTAssertEqual(
            alert.buttons.map(\.title),
            ["Open in New Window", "Open in This Window", "Cancel"]
        )
        XCTAssertEqual(alert.suppressionButton?.title, "Remember my choice")

        alert.suppressionButton?.state = .on
        XCTAssertEqual(
            prompter.response(for: .alertFirstButtonReturn, from: alert),
            ProjectOpenDestinationPromptResponse(choice: .newWindow, remembersChoice: true)
        )
        XCTAssertEqual(
            prompter.response(for: .alertSecondButtonReturn, from: alert).choice,
            .currentWindow
        )
        XCTAssertEqual(
            prompter.response(for: .alertThirdButtonReturn, from: alert).choice,
            .cancel
        )
    }
}
