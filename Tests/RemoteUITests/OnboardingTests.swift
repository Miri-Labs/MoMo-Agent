import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    func testFirstUseConnectsBeforeTabsAndCanResume() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["welcome.page.family"].exists)
        XCTAssertFalse(app.buttons["welcome.replay"].exists)
        let start = app.buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "The automatic story should finish within ten seconds")
        start.tap()
        XCTAssertTrue(app.buttons["onboarding.loginTailscale"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["remote.scanMac"].exists, "Join the network before scanning")
        XCTAssertFalse(app.buttons["onboarding.networkPrepared"].exists, "Login cannot be skipped as if already connected")
        capture(app, "Onboarding — embedded Tailscale login")
        app.buttons["onboarding.more"].tap()
        app.buttons["onboarding.otherNetwork"].tap()
        XCTAssertTrue(app.buttons["remote.scanMac"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "First connection belongs before the main workspace")
        XCTAssertFalse(app.textViews["remote.connectionJSON"].exists, "No technical JSON in onboarding")
        XCTAssertFalse(app.buttons["remote.pickQR"].exists)
        capture(app, "Onboarding — connect Mac before tabs")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["onboarding.loginTailscale"].waitForExistence(timeout: 20), "Resume connection, do not replay introduction")
        app.buttons["onboarding.more"].tap()
        app.buttons["onboarding.otherNetwork"].tap()
        XCTAssertTrue(app.buttons["remote.scanMac"].waitForExistence(timeout: 10))
        app.buttons["稍后配对"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["转录"].isSelected)
        app.tabBars.buttons["聊天"].tap()
        app.buttons["remote.connect"].tap()
        XCTAssertTrue(app.buttons["onboarding.loginTailscale"].waitForExistence(timeout: 10))
        app.buttons["onboarding.more"].tap()
        app.buttons["onboarding.otherNetwork"].tap()
        XCTAssertTrue(app.buttons["remote.scanMac"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        capture(app, "Onboarding — resume from chat")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
