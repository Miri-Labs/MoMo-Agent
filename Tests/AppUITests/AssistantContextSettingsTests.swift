import XCTest

@MainActor
final class AssistantContextSettingsTests: XCTestCase {
    func testUserProfileSavesSurvivesRestartAndCanBeCleared() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        openContext(app)
        XCTAssertTrue(app.buttons["settings.context.soul"].exists)
        XCTAssertTrue(app.buttons["settings.context.memory"].exists)
        app.buttons["settings.context.user"].tap()
        let editor = app.textViews["settings.context.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("I prefer short answers.")
        app.buttons["settings.context.save"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"),
                                             object: app.buttons["settings.context.save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["settings.context.failure"].exists)
        app.terminate()
        app.launch()
        openContext(app)
        app.buttons["settings.context.user"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "I prefer short answers.")
        app.swipeUp()
        app.buttons["settings.context.reset"].tap()
        let clear = app.buttons.matching(identifier: "清空内容")
        clear.element(boundBy: clear.count - 1).tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == ''"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["settings.context.failure"].exists)
    }

    private func openContext(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        let context = app.buttons["settings.context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        context.tap()
        XCTAssertTrue(app.navigationBars["个性与记忆"].waitForExistence(timeout: 5))
    }
}
