import XCTest

@MainActor
final class PhoneStorageJourneyTests: XCTestCase {
    func testStorageUsesActualFilesWithoutModelManagement() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        let storage = app.buttons["settings.storage"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        storage.tap()
        let audio = app.descendants(matching: .any).matching(identifier: "storage.audio").firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 15))
        for id in ["storage.models", "storage.available"] {
            let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
            for _ in 0..<5 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists)
        }
        XCTAssertFalse(app.staticTexts["storage.modelStatus"].exists)
        XCTAssertFalse(app.staticTexts["SenseVoiceSmall · Silero VAD"].exists)
        XCTAssertFalse(app.staticTexts["模型已校验并加载，可以离线转写。"].exists)
        app.buttons["storage.refresh"].tap()
    }
    func testStorageShowsAutomaticPolicyWithoutManualAudioManagement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.storage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.retention"].exists)
        app.buttons["settings.storage"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["storage.retention.current"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["storage.limit.current"].exists)
        XCTAssertFalse(app.textFields["storage.limit.input"].exists)
        XCTAssertFalse(app.buttons["storage.limit.save"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "storage-automatic-audio-management"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
