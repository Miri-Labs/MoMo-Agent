import XCTest

@MainActor
final class NetworkSettingsTests: XCTestCase {
    func testUnpairedDevicePageKeepsManualConfigurationSeparate() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["welcome.skip"].waitForExistence(timeout: 30))
        app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
        XCTAssertTrue(app.buttons["稍后配对"].waitForExistence(timeout: 15))
        app.buttons["稍后配对"].tap()
        app.tabBars.buttons["聊天"].tap()
        app.buttons["remote.settings"].tap()
        let deviceEntry = app.buttons["settings.mac"]
        XCTAssertTrue(deviceEntry.waitForExistence(timeout: 10))
        XCTAssertTrue(deviceEntry.label.contains("配对"))
        deviceEntry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.deviceState"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["remote.deviceState"].label.contains("尚未配对"))
        XCTAssertTrue(app.buttons["扫码配对"].exists)
        XCTAssertFalse(app.textViews["remote.connectionJSON"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["remote.networkRoute"].exists)
        capture(app, "Devices — unpaired")
        app.buttons["remote.manualConnection"].tap()
        XCTAssertTrue(app.textViews["remote.connectionJSON"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["remote.credential"].exists)
        XCTAssertFalse(app.buttons["remote.saveConnection"].isEnabled)
        app.navigationBars["手动配置"].buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["扫码配对"].exists)
    }

    func testPairedDevicePageShowsNetworkDetailsInline() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "F33D4EAE-9622-40DE-B23F-A6FDE416A074"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "remote"
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
        }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 30) {
            app.buttons["onboarding.finish"].tap()
        }
        XCTAssertTrue(app.buttons["remote.settings"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["remote.settings"].tap()
        app.buttons["settings.mac"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.deviceState"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["重新配对"].exists)
        XCTAssertFalse(app.buttons["remote.connectionDetails"].exists)
        XCTAssertFalse(app.textViews["remote.connectionJSON"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "remote.pairDevice").count, 1)
        capture(app, "Devices — paired")
        let route = app.descendants(matching: .any)["remote.networkRoute"].firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
            route.label.contains("WebRTC") || (route.value as? String)?.contains("WebRTC") == true
        }, object: nil)], timeout: 30)
        capture(app, "Devices — network details")
        app.buttons["remote.manualConnection"].tap()
        capture(app, "Devices — manual configuration")
        XCTAssertTrue(app.textViews["remote.connectionJSON"].exists)
        app.navigationBars["手动配置"].buttons["BackButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote.deviceState"].label.contains("已配对"))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
