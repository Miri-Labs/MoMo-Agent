import XCTest

/// Opt-in paid UI journey. The runner injects only a public run ID into this process.
@MainActor
final class PhoneLiveAgentJourneyTests: XCTestCase {
    private let prompt = "What was just discussed? Keep it brief, cite the source and do not guess unclear details."

    func testRealASRAnswersThroughChatWithoutCreatingArtifacts() throws {
        guard let value = ProcessInfo.processInfo.environment["MOMO_LIVE_UI_RUN_ID"] else {
            throw XCTSkip("Live UI Agent tests require the explicit credential-file runner.")
        }
        let runID = try XCTUnwrap(UUID(uuidString: value)).uuidString
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_IMPORT_FIXTURE"] = "1"
        app.launchEnvironment["MOMO_UI_TEST_LIVE_AGENT"] = "1"
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["assistant.library"].waitForExistence(timeout: 20))
        app.buttons["assistant.library"].tap()
        let recording = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 30))
        recording.tap()
        let transcript = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.text.")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 120), "The source must be produced by local ASR before the task is sent.")
        let actualTranscript = transcript.label
        XCTAssertTrue(actualTranscript.contains("早上9点") && actualTranscript.contains("下午5点"))
        attach(app, name: "live-ui-real-asr")
        goBack(app)
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["聊天"].tap()

        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(prompt)
        let send = app.buttons["assistant.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        waitForLabel("停止回复", on: send, timeout: 10)
        waitForLabel("发送", on: send, timeout: 150)
        XCTAssertFalse(app.buttons["assistant.retry"].exists)
        revealSource(app)
        attach(app, name: "live-ui-agent-answer")

        verifySource(app, transcript: actualTranscript, play: true)
        attach(app, name: "live-ui-source-return")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MOMO_UI_TEST_IMPORT_FIXTURE")
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        app.buttons["assistant.sidebar"].tap()
        let chat = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.chat.")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.staticTexts[prompt].waitForExistence(timeout: 10))
        revealSource(app)
        attach(app, name: "live-ui-chat-after-restart")

        let evidence: [String: Any] = ["runID": runID, "actualTranscript": actualTranscript,
            "prompt": prompt, "sourcePlaybackObserved": true, "chatRestored": true]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "live-ui-journey"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func verifySource(_ app: XCUIApplication, transcript: String, play: Bool) {
        revealSource(app)
        let source = app.links.firstMatch
        source.tap()
        XCTAssertTrue(app.navigationBars["原文"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[transcript].waitForExistence(timeout: 5), "The cited source must display the actual ASR text.")
        if play {
            let playback = app.buttons["回放这段原音"]
            XCTAssertTrue(playback.waitForExistence(timeout: 5))
            playback.tap()
            let stop = app.buttons["暂停回听"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5), "The source must reach native playback, not just open a sheet.")
            attach(app, name: "live-ui-source-playing")
            stop.tap()
            XCTAssertTrue(playback.waitForExistence(timeout: 5))
        }
        app.buttons["完成"].tap()
    }

    private func revealSource(_ app: XCUIApplication) {
        let source = app.links.firstMatch
        for _ in 0..<5 {
            if source.exists && source.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(source.exists && source.isHittable, "The model must cite the recording inline in its answer.")
        XCTAssertFalse(app.staticTexts["参考原文"].exists)
        XCTAssertFalse(app.buttons["原文 1"].exists, "An automatically appended source cannot stand in for a model citation.")
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
