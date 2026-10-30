import XCTest

@MainActor
final class PhoneConnectionOnboardingTests: XCTestCase {
    func testOnboardingUsesFlatConnectionsAndCanContinueWithoutConnecting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "NO"]
        app.launch()
        defer { app.terminate() }
        let skip = app.buttons["welcome.skip"]
        if skip.waitForExistence(timeout: 10) { skip.tap() }
        XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 40))
        for source in ["health", "calendar", "reminders", "alarms", "location"] {
            let toggle = app.switches["connections.\(source).toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0")
        }
        XCTAssertTrue(app.switches["web.enabled"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["web.enabled"].value as? String, "0")
        XCTAssertFalse(app.buttons["system.history"].exists)
        XCTAssertFalse(app.buttons["connections.more"].exists)
        XCTAssertFalse(app.buttons["connections.mail.details"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["welcome.gmailLater"].exists)
        XCTAssertFalse(app.buttons["connections.mail.setup"].exists)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
            object: app.switches["connections.health.toggle"])
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        app.switches["connections.health.toggle"].tap()
        let consent = app.alerts["用于 MoMo 对话"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertTrue(consent.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "静息心率")).firstMatch.exists)
        consent.buttons["取消"].tap()
        XCTAssertEqual(app.switches["connections.health.toggle"].value as? String, "0")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "onboarding-flat-connections"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["welcome.start"].tap()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 10))
    }
}
