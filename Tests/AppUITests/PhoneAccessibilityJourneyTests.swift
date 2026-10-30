import XCTest

@MainActor
final class PhoneAccessibilityJourneyTests: XCTestCase {
    func testRelaunchRestoresSelectedConversationAndUnsentDraftWithoutCredentials() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["assistant.newChat"].waitForExistence(timeout: 15))
        app.buttons["assistant.newChat"].tap()
        app.buttons["assistant.sidebar"].tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.chat.' AND selected == true")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        let selectedID = selected.identifier
        app.buttons["sidebar.close"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["sidebar.drawer"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        let draft = "Keep this draft local until I choose to send it."
        input.tap()
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)

        app.terminate()
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
        app.buttons["assistant.sidebar"].tap()
        let restored = app.buttons[selectedID]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.isSelected, "Cold launch must restore the same selected conversation, not just its list entry.")
        app.buttons["sidebar.close"].tap()
        XCTAssertEqual(input.value as? String, draft)
        attach(app, name: "acceptance-relaunch-restores-local-draft-and-session")
    }

    func testHomeDrawerAndSettingsKeepNamedReachableControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        let menu = app.buttons["assistant.sidebar"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        for control in [menu, app.buttons["assistant.watchStatus"], app.buttons["assistant.newChat"], app.buttons["assistant.library"]] {
            XCTAssertTrue(control.isHittable)
            XCTAssertFalse(control.label.isEmpty)
        }
        for control in [app.buttons["assistant.watchStatus"], app.buttons["assistant.library"]] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        // Native toolbar glyph frames exclude UIKit's extended hit area; audit that area with the system.
        attach(app, name: "acceptance-home-accessibility")
        try audit(app, stage: "home")

        menu.tap()
        let newChat = app.buttons["sidebar.newChat"]
        let settings = app.buttons["sidebar.settings"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        XCTAssertTrue(newChat.isHittable && settings.isHittable)
        attach(app, name: "acceptance-drawer-accessibility")
        try audit(app, stage: "drawer")
        settings.tap()
        XCTAssertTrue(app.buttons["settings.provider"].waitForExistence(timeout: 5))
        attach(app, name: "acceptance-settings-accessibility")
        try audit(app, stage: "settings")
    }

    private func audit(_ app: XCUIApplication, stage: String) throws {
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription, .textClipped]) { issue in
            let details = XCTAttachment(string: "\(issue.compactDescription)\n\(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No associated element")")
            details.name = "accessibility-\(stage)-issue"
            details.lifetime = .keepAlways
            self.add(details)
            return false // Record every issue; extra context must never suppress a failure.
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
