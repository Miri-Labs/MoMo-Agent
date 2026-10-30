import XCTest

@MainActor
final class PhoneHistoryDrawerTests: XCTestCase {
    func testEdgeDragOpensAndLeftDragClosesWithoutLosingDraft() {
        let app = launch()
        defer { app.terminate() }
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        input.tap()
        input.typeText("Keep my draft through swipes.")
        drag(app, from: .init(dx: 0.02, dy: 0.35), to: .init(dx: 0.72, dy: 0.35))
        let drawer = app.otherElements["sidebar.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sidebar.search.toggle"].isHittable)
        XCTAssertEqual(drawer.frame.minX, 0, accuracy: 2)
        attach(app, name: "history-edge-drag-open")
        drag(app, from: .init(dx: 0.65, dy: 0.35), to: .init(dx: 0.03, dy: 0.35))
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 5))
        assertClosed(app)
        XCTAssertEqual(input.value as? String, "Keep my draft through swipes.")
        attach(app, name: "history-left-drag-closed-draft-kept")
        app.buttons["assistant.sidebar"].tap()
        XCTAssertTrue(app.buttons["sidebar.search.toggle"].waitForExistence(timeout: 5))
        app.buttons["sidebar.close"].tap()
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep my draft through swipes.")
    }

    func testShortDragCancelsAndVerticalOrCenterDragsDoNotOpenHistory() {
        let app = launch()
        defer { app.terminate() }
        drag(app, from: .init(dx: 0.02, dy: 0.35), to: .init(dx: 0.18, dy: 0.35))
        assertClosed(app)
        drag(app, from: .init(dx: 0.02, dy: 0.50), to: .init(dx: 0.03, dy: 0.25))
        assertClosed(app)
        drag(app, from: .init(dx: 0.35, dy: 0.35), to: .init(dx: 0.85, dy: 0.35))
        assertClosed(app)
        app.buttons["assistant.sidebar"].tap()
        XCTAssertTrue(app.buttons["sidebar.search.toggle"].isHittable)
        drag(app, from: .init(dx: 0.60, dy: 0.35), to: .init(dx: 0.50, dy: 0.35))
        XCTAssertTrue(app.buttons["sidebar.search.toggle"].isHittable)
        drag(app, from: .init(dx: 0.40, dy: 0.50), to: .init(dx: 0.39, dy: 0.25))
        XCTAssertTrue(app.buttons["sidebar.search.toggle"].isHittable)
        app.buttons["sidebar.close"].tap()
    }

    func testTranscriptTabAndSettingsKeepTheirOwnGestures() {
        let app = launch()
        defer { app.terminate() }
        app.tabBars.buttons["转录"].tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        drag(app, from: .init(dx: 0.02, dy: 0.35), to: .init(dx: 0.72, dy: 0.35))
        assertClosed(app)
        app.tabBars.buttons["聊天"].tap()
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.provider"].waitForExistence(timeout: 5))
        drag(app, from: .init(dx: 0.02, dy: 0.35), to: .init(dx: 0.85, dy: 0.35))
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
                                                object: app.buttons["assistant.sidebar"])
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        assertClosed(app)
        attach(app, name: "settings-edge-back-without-history")
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 20))
        return app
    }

    private func drag(_ app: XCUIApplication, from: CGVector, to: CGVector) {
        app.coordinate(withNormalizedOffset: from).press(forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: .slow,
            thenHoldForDuration: 0.3)
    }

    private func assertClosed(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // The offscreen container stays mounted to follow the finger without re-creating the list.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.otherElements["sidebar.drawer"].frame.maxX <= 1
                && !app.buttons["sidebar.search.toggle"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
