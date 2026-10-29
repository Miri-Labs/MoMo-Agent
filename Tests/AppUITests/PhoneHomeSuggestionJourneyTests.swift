import XCTest

@MainActor
final class PhoneHomeSuggestionJourneyTests: XCTestCase {
    func testCardsSendDirectlyToAgentAndTypingHidesSuggestions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launchEnvironment["MOMO_UI_TEST_HOME_SUGGESTIONS"] = "1"
        app.launchEnvironment["MOMO_UI_TEST_CONTROLLED_STREAM"] = "stop-regenerate-retry"
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        let card = app.buttons["assistant.suggestion.synthetic-plan"]
        let other = app.buttons["assistant.suggestion.synthetic-ideas"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(other.exists)
        XCTAssertEqual(card.frame.minY, other.frame.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(card.frame.height, 220)
        XCTAssertEqual(card.frame.height, other.frame.height, accuracy: 1)
        assertHomeLayout(app, card: card)
        XCTAssertTrue(card.isHittable)
        let avatar = app.buttons["personalAgent.avatar"]
        XCTAssertTrue(avatar.exists)
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // Inspect the visible head, excluding the name and Watch badge.
            guard let source = avatar.screenshot().image.cgImage,
                  let pixels = source.cropping(to: CGRect(x: 0, y: 0, width: Double(source.width),
                      height: Double(source.height) * 0.75)) else { return false }
            return Self.darkPixels(in: pixels) > 500
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 15), .completed,
            "Wait for the original Avatar to paint before reviewing the home screen.")
        attach(app, name: "home-suggestions-light")
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        input.tap(); input.typeText("Preserve this draft")
        XCTAssertFalse(card.exists)
        XCTAssertEqual(input.value as? String, "Preserve this draft")
        // Opening the drawer ends focus; clearing the draft restores the evidence-backed cards.
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 19))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let userMessage = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "梳理时间线方案")).firstMatch
        XCTAssertTrue(userMessage.waitForExistence(timeout: 15), "A card submits a visible message without another Send tap.")
        XCTAssertFalse(card.exists)
        XCTAssertTrue(app.buttons["assistant.send"].waitForExistence(timeout: 5))
        let inHeader = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            avatar.frame.width < 100 && avatar.frame.maxY < app.frame.height * 0.3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [inHeader], timeout: 5), .completed)
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        attach(app, name: "suggestion-sent-to-agent")
        if app.buttons["assistant.send"].label == "停止回复" { app.buttons["assistant.send"].tap() }
    }

    func testSingleLongSuggestionUsesFullWidthWithoutCoveringAvatarOrComposer() {
        let app = launchSuggestions("single-long")
        defer { app.terminate() }
        let card = app.buttons["assistant.suggestion.synthetic-plan"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(card.frame.width, app.frame.width * 0.85)
        XCTAssertLessThanOrEqual(card.frame.height, 160)
        assertHomeLayout(app, card: card)
        attach(app, name: "single-long-suggestion")
        card.press(forDuration: 1)
        app.buttons["暂时收起"].tap()
        XCTAssertFalse(card.exists)
        let welcome = app.staticTexts["assistant.welcome"]
        let name = app.staticTexts["personalAgent.name"]
        XCTAssertLessThan(name.frame.maxY, welcome.frame.minY)
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        attach(app, name: "home-after-dismissing-last-suggestion")
    }

    func testTwoLongSuggestionsStayCompactAndRemainingCardExpands() {
        let app = launchSuggestions("pair-long")
        defer { app.terminate() }
        let card = app.buttons["assistant.suggestion.synthetic-plan"]
        let other = app.buttons["assistant.suggestion.synthetic-ideas"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(other.exists)
        XCTAssertEqual(card.frame.minY, other.frame.minY, accuracy: 1)
        XCTAssertEqual(card.frame.height, other.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(card.frame.height, 220)
        assertHomeLayout(app, card: card)
        attach(app, name: "two-long-suggestions")
        other.press(forDuration: 1)
        app.buttons["暂时收起"].tap()
        XCTAssertFalse(other.exists)
        XCTAssertGreaterThan(card.frame.width, app.frame.width * 0.85)
        assertHomeLayout(app, card: card)
        attach(app, name: "remaining-suggestion-expands")
    }

    private func launchSuggestions(_ fixture: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launchEnvironment["MOMO_UI_TEST_HOME_SUGGESTIONS"] = fixture
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        return app
    }

    private func assertHomeLayout(_ app: XCUIApplication, card: XCUIElement) {
        let avatar = app.buttons["personalAgent.avatar"]
        let name = app.staticTexts["personalAgent.name"]
        let welcome = app.staticTexts["assistant.welcome"]
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(avatar.exists)
        XCTAssertTrue(name.exists)
        XCTAssertTrue(welcome.exists)
        XCTAssertLessThan(avatar.frame.maxY, welcome.frame.minY)
        XCTAssertLessThan(name.frame.maxY, welcome.frame.minY)
        XCTAssertLessThan(welcome.frame.maxY, card.frame.minY)
        XCTAssertLessThan(card.frame.maxY, input.frame.minY)
        XCTAssertTrue(card.isHittable)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private static func darkPixels(in pixels: CGImage) -> Int {
        var rgba = [UInt8](repeating: 0, count: pixels.width * pixels.height * 4)
        return rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            return stride(from: 0, to: buffer.count, by: 4).filter {
                buffer[$0] < 100 && buffer[$0 + 1] < 100 && buffer[$0 + 2] < 100 && buffer[$0 + 3] > 200
            }.count
        }
    }
}
