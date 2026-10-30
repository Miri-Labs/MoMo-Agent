import XCTest

@MainActor
final class PhoneRecordingJourneyTests: XCTestCase {
    func testTranscriptionRunsAutomaticallyWithoutManualControls() throws {
        continueAfterFailure = false
        let runID = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_IMPORT_FIXTURE"] = "1"
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        openLibrary(app)
        XCTAssertFalse(app.buttons["library.transcription.toggle"].exists)
        XCTAssertFalse(app.buttons["library.batch.start"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.batch.resume.")).count, 0)
        XCTAssertFalse(app.staticTexts["本机转写已就绪"].exists)
        attachScreenshot(app, name: "automatic-transcription-without-controls")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let text = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.text.")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 120), "Actual ASR must finish without a start or resume action.")
        XCTAssertTrue(text.label.contains("早上9点"))
        let original = text.label
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["timeline.search.toggle"].tap()
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("早上9点")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.search.result.")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "The search must match the actual local transcript.")
        result.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.label, original)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MOMO_UI_TEST_IMPORT_FIXTURE")
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        openLibrary(app)
        XCTAssertFalse(app.buttons["library.transcription.toggle"].exists)
        XCTAssertFalse(app.staticTexts["本机转写已就绪"].exists)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertEqual(text.label, original)
    }

    func testMarkedSilenceKeepsTimePlaybackWithoutAudioManagementAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_IMPORT_FIXTURE"] = "silence"
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        openLibrary(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        XCTAssertTrue(app.staticTexts["未识别到语音"].waitForExistence(timeout: 120))
        XCTAssertFalse(app.buttons["timeline.detail.more"].exists)
        XCTAssertFalse(app.buttons["transcript.discuss"].exists)
        let play = app.buttons["transcript.recording.play"]
        XCTAssertTrue(play.exists)
        play.tap()
        waitForLabel("暂停回听", element: play)
        play.tap()
        waitForLabel("继续回听", element: play)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MOMO_UI_TEST_IMPORT_FIXTURE")
        app.launch()
        openLibrary(app)
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.staticTexts["未识别到语音"].waitForExistence(timeout: 10))
        XCTAssertTrue(play.exists)
        XCTAssertFalse(app.buttons["timeline.detail.more"].exists)
    }

    func testAudioPlayerPauseSeekMiniAndClosePreserveRecording() throws {
        continueAfterFailure = false
        let runID = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        // Real decoded audio with PCM padding leaves time to observe resume before natural completion.
        app.launchEnvironment["MOMO_UI_TEST_IMPORT_FIXTURE"] = "speech-playback"
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        openLibrary(app)
        XCTAssertFalse(app.buttons["playback.mini.toggle"].exists, "No mini player without a real playback target.")
        let recording = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 30))
        recording.tap()
        let transcript = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.text.")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 120))
        let paragraph = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.play.")).firstMatch
        paragraph.tap()
        waitForLabel("暂停回听这段文字", element: paragraph)
        paragraph.tap()
        returnToTimelineLibrary(app)
        app.buttons["playback.mini.open"].tap()
        XCTAssertTrue(app.navigationBars["录音"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["transcript.more.export"].exists)
        XCTAssertFalse(app.buttons["transcript.more.retention"].exists)
        XCTAssertFalse(app.buttons["recording.files.restore"].exists)
        let play = app.buttons["transcript.recording.play"]
        XCTAssertTrue(play.isHittable)
        play.tap()
        waitForLabel("暂停回听", element: play)
        play.tap()
        waitForLabel("继续回听", element: play)

        let seek = app.descendants(matching: .any).matching(identifier: "transcript.recording.play.seek").firstMatch
        XCTAssertTrue(seek.isHittable)
        let beforeSeek = try XCTUnwrap(seek.value as? String)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", beforeSeek), object: seek)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed)
        waitForLabel("继续回听", element: play)
        XCTAssertFalse(app.staticTexts["transcript.recording.play.failure"].exists)
        let pausedPosition = try XCTUnwrap(seek.value as? String)
        play.tap()
        waitForLabel("暂停回听", element: play)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", pausedPosition), object: seek)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed,
                       "Resume must advance the real audio clock from the selected position.")
        play.tap()
        waitForLabel("继续回听", element: play)
        attachScreenshot(app, name: "player-paused-after-real-seek")

        returnToTimelineLibrary(app)
        let toggle = app.buttons["playback.mini.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        waitForLabel("继续回听", element: toggle)
        toggle.tap()
        waitForLabel("暂停回听", element: toggle)
        XCTAssertTrue(app.navigationBars["转录"].exists, "Pause/resume must not also navigate.")
        toggle.tap()
        waitForLabel("继续回听", element: toggle)
        app.buttons["playback.mini.open"].tap()
        XCTAssertTrue(app.navigationBars["录音"].waitForExistence(timeout: 5))
        waitForLabel("继续回听", element: play)
        XCTAssertTrue(transcript.label.contains("早上9点"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["playback.mini.close"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["转录"].exists)
        XCTAssertTrue(recording.exists, "Closing playback must keep the recording and its transcript.")
        attachScreenshot(app, name: "mini-player-closed-recording-preserved")
    }

    func testRealLocalTranscriptionAndTimeReferenceSurviveRelaunch() throws {
        continueAfterFailure = false
        let runID = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_IMPORT_FIXTURE"] = "1"
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        openLibrary(app)
        let recording = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 30))
        recording.tap()
        let transcript = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.text.")).firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 120), "The real local ASR result must be visible.")
        let originalText = transcript.label
        XCTAssertTrue(originalText.contains("早上9点"))
        XCTAssertTrue(originalText.contains("下午5点"))
        // This journey checks real transcription delivery and persistence. The fixed sample's
        // opening-word substitution remains an ASR quality failure, recorded separately from UI status.
        let quality = XCTAttachment(string: "Reference: 开放时间早上9点至下午5点。\nActual: \(originalText)")
        quality.name = "real-asr-quality-observation"
        quality.lifetime = .keepAlways
        add(quality)
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.play.")).firstMatch
        XCTAssertTrue(play.exists)
        play.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "暂停回听这段文字"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
        play.tap()
        attachScreenshot(app, name: "real-transcript-and-playback")
        XCTAssertFalse(app.buttons["timeline.detail.more"].exists)
        XCTAssertFalse(app.switches["transcript.keepAudio"].exists)
        app.buttons["transcript.discuss"].tap()
        let reference = app.staticTexts["已引用这段时间"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["assistant.send"].isEnabled, "Selecting a recording must not send an empty task.")
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
        attachScreenshot(app, name: "recording-reference-in-chat-draft")
        let removeReference = app.buttons["assistant.source.remove"]
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        let removable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: removeReference)
        XCTAssertEqual(XCTWaiter.wait(for: [removable], timeout: 5), .completed)
        // Centered CGRect coordinates can differ from 44pt by floating-point rounding.
        XCTAssertGreaterThanOrEqual(removeReference.frame.width, 44 - 0.000001, "The removal control must expose its full touch target.")
        XCTAssertGreaterThanOrEqual(removeReference.frame.height, 44 - 0.000001, "The removal control must expose its full touch target.")
        removeReference.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !reference.exists && !removeReference.exists && input.placeholderValue == "说说你想做的事…"
        }, object: nil)
        let clearResult = XCTWaiter.wait(for: [cleared], timeout: 5)
        if clearResult != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "recording-reference-removal-failure-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            attachScreenshot(app, name: "recording-reference-removal-failure")
        }
        XCTAssertEqual(clearResult, .completed, "Removing a reference must clear the chip, remove button, and recording-specific prompt.")
        XCTAssertFalse(reference.exists)
        XCTAssertFalse(removeReference.exists)
        XCTAssertEqual(input.placeholderValue, "说说你想做的事…")
        attachScreenshot(app, name: "recording-reference-removed")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MOMO_UI_TEST_IMPORT_FIXTURE")
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        openLibrary(app)
        XCTAssertTrue(recording.waitForExistence(timeout: 15))
        recording.tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertEqual(transcript.label, originalText, "Relaunch must preserve the complete actual ASR text.")
        XCTAssertFalse(app.buttons["timeline.detail.more"].exists)
        attachScreenshot(app, name: "transcription-survives-relaunch-without-audio-management")
    }

    private func openLibrary(_ app: XCUIApplication) {
        let button = app.tabBars.buttons["转录"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
    }

    private func waitForLabel(_ label: String, element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file, line: line)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}


@MainActor
extension XCTestCase {
    func returnToTimelineLibrary(_ app: XCUIApplication) {
        for _ in 0..<3 {
            if app.navigationBars["转录"].exists { return }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.navigationBars["转录"].exists)
    }
}
