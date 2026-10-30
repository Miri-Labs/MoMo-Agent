import XCTest

/// Opt-in integration check. A synthetic Mac fixture supplies a QR image in Photos and
/// approves only its test device through the local control port; no personal data is used.
@MainActor
final class PairingFlowTests: XCTestCase {
    func testQRImageApprovalEntersChat() async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18778/status"))
        var request = URLRequest(url: url); request.timeoutInterval = 2
        let response = try? await URLSession.shared.data(for: request)
        try XCTSkipUnless((response?.1 as? HTTPURLResponse)?.statusCode == 200, "Start the synthetic pairing fixture and import its QR image first")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 30))
        app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
        XCTAssertTrue(app.buttons["remote.pickQR"].waitForExistence(timeout: 15))
        app.buttons["remote.pickQR"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), app.debugDescription)
        photo.tap()
        XCTAssertTrue(app.staticTexts["remote.pairCode"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.buttons["remote.scanMac"].exists, "Pending approval is the primary step")
        capture(app, "Pairing — compare numbers before approval")
        XCTAssertTrue(app.buttons["onboarding.finish"].waitForExistence(timeout: 40), app.debugDescription)
        capture(app, "Pairing — verified connection")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.tabBars.buttons["聊天"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["聊天"].isSelected)
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["聊天"].waitForExistence(timeout: 20), "Connected launch must not repeat onboarding")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
