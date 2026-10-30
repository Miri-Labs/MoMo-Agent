import XCTest

/// Real App/Pi/URLSession/WK and native audio, with synthetic in-process SSE input.
/// This does not test an external provider, local ASR, timeout/429, or model answer quality.
@MainActor
final class PhoneControlledStreamJourneyTests: XCTestCase {
    private let question = "Summarize only this selected timeline and cite its source."
    private let draft = "Keep this unsent draft."

    func testNewConversationFinishesWhileTheFirstKeepsStreamingAndDraftsStayIndependent() {
        let (app, runID) = launch("parallel-conversations")
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let avatar = app.buttons["personalAgent.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(avatar.frame.midY, app.frame.height * 0.25)
        XCTAssertGreaterThan(avatar.frame.width, 130)
        attach(app, name: "momo-centered-before-first-message")
        input.tap(); input.typeText("Parallel conversation A")
        waitForKeyboard(app)
        tapSendControl(app, label: "发送", name: "parallel-a-send")
        XCTAssertTrue(text(app, containing: "会话 A 已开始生成").waitForExistence(timeout: 20))
        XCTAssertLessThan(avatar.frame.midY, app.frame.height * 0.2)
        XCTAssertLessThan(avatar.frame.width, 100)
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        attach(app, name: "momo-at-top-after-first-message")
        app.tabBars.buttons["转录"].tap()
        XCTAssertTrue(app.buttons["timeline.datePicker"].waitForExistence(timeout: 5))
        app.tabBars.buttons["聊天"].tap()
        wait(app.buttons["assistant.send"], label: "停止回复")
        XCTAssertTrue(text(app, containing: "会话 A 已开始生成").exists)
        attach(app, name: "parallel-a-still-streaming-after-tab-switch")
        XCTAssertTrue(app.buttons["assistant.newChat"].isEnabled)
        app.buttons["assistant.newChat"].tap()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 10))
        let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            avatar.frame.midY > app.frame.height * 0.25 && avatar.frame.width > 130
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, "")
        input.tap(); input.typeText("Parallel conversation B")
        waitForKeyboard(app)
        tapSendControl(app, label: "发送", name: "parallel-b-send")
        XCTAssertTrue(text(app, containing: "会话 B 已独立完成回答").waitForExistence(timeout: 20))
        wait(app.buttons["assistant.send"], label: "发送")
        input.tap(); input.typeText("Draft B")
        app.buttons["assistant.sidebar"].tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.chat.' AND label CONTAINS %@", "Parallel conversation A")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.value as? String, "正在回复")
        XCTAssertTrue(app.buttons["sidebar.newChat"].isEnabled)
        first.tap()
        XCTAssertTrue(text(app, containing: "会话 A 已开始生成").waitForExistence(timeout: 10))
        wait(app.buttons["assistant.send"], label: "停止回复")
        input.tap(); input.typeText("Draft A")
        waitForKeyboard(app)
        tapSendControl(app, label: "停止回复", name: "parallel-a-stop")
        wait(app.buttons["assistant.send"], label: "发送")
        app.buttons["assistant.sidebar"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.chat.' AND label CONTAINS %@", "Parallel conversation B")).firstMatch.tap()
        waitForDraft(input, text: "Draft B")
        XCTAssertEqual(input.value as? String, "Draft B")
        XCTAssertTrue(text(app, containing: "会话 B 已独立完成回答").exists)
        XCTAssertFalse(text(app, containing: "会话 A 已开始生成").exists)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
        attach(app, name: "parallel-b-complete-a-stopped")
        app.terminate(); app.launch()
        XCTAssertTrue(text(app, containing: "会话 B 已独立完成回答").waitForExistence(timeout: 20))
        XCTAssertEqual(input.value as? String, "Draft B")
        app.buttons["assistant.sidebar"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.chat.' AND label CONTAINS %@", "Parallel conversation A")).firstMatch.tap()
        waitForDraft(input, text: "Draft A")
        XCTAssertEqual(input.value as? String, "Draft A")
        wait(app.buttons["assistant.send"], label: "发送")
        attach(app, name: "parallel-a-restored-own-draft")
        let observation = XCTAttachment(string: "runID=\(runID); parallel-conversations; expected two different sessions, second completed before first cancelled; relaunch adds zero requests")
        observation.name = "parallel-run-identity"; observation.lifetime = .keepAlways; add(observation)
    }

    private func waitForDraft(_ input: XCUIElement, text: String) {
        // History selection is asynchronous; wait for its actual committed draft,
        // rather than treating the drawer's closing animation as a load barrier.
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    }

    func testCancelBeforeFirstResponseBytePreservesDraftAndDoesNotResendOnRelaunch() {
        let (app, runID) = launch("cancel-before-body")
        selectTimelineAndSend(app)
        let send = app.buttons["assistant.send"]
        wait(send, label: "停止回复")
        XCTAssertTrue(text(app, containing: question).waitForExistence(timeout: 10))
        let input = composer(app)
        input.tap(); input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        waitForKeyboard(app)
        tapSendControl(app, label: "停止回复", name: "controlled-stream-before-first-byte-stop")
        assertCancelledBeforeBody(app)
        attach(app, name: "controlled-stream-before-first-byte-cancelled")

        app.terminate(); app.launch()
        assertCancelledBeforeBody(app)
        attach(app, name: "controlled-stream-before-first-byte-relaunched")
        // Busy UI alone does not prove provider admission. A separate read-only check
        // must find the request and exactly request -> headers-200 -> cancelled, with
        // zero body bytes, cancelled attempt 0 and no additional request after relaunch.
        evidence(runID, scenario: "cancel-before-body", expectedHTTPRequests: 1,
                 expectedOperationRelationship: "one admitted operation; appAttempt=0; cancelled; zero response bytes; launchRequestCounts=[0,1]; no resend")
    }

    func testStopRegenerate503RetryCitationPlaybackAndRelaunchPreserveDraft() {
        let (app, runID) = launch("stop-regenerate-retry")
        selectTimelineAndSend(app)
        let send = app.buttons["assistant.send"]
        wait(send, label: "停止回复")
        XCTAssertTrue(text(app, containing: "受控流式第一段已经到达").waitForExistence(timeout: 20))
        let avatar = app.buttons["personalAgent.avatar"]
        XCTAssertTrue(avatar.exists)
        XCTAssertTrue(app.personalAgentHasVisiblePixels())
        XCTAssertEqual(app.staticTexts["personalAgent.name"].label, "MoMo")
        XCTAssertEqual(app.buttons.matching(identifier: "personalAgent.avatar").count, 1)
        let headerY = avatar.frame.midY
        XCTAssertLessThan(headerY, app.frame.height * 0.2)
        attach(app, name: "controlled-stream-partial-before-stop")
        let input = composer(app)
        input.tap(); input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        waitForKeyboard(app)
        XCTAssertEqual(avatar.frame.midY, headerY, accuracy: 1, "The Avatar stays in the header while the keyboard opens.")
        XCTAssertEqual(send.label, "停止回复")
        tapSendControl(app, label: "停止回复", name: "controlled-stream-stop")
        wait(send, label: "发送")
        XCTAssertTrue(text(app, containing: "受控流式第一段已经到达").exists)
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertFalse(app.staticTexts["已停止"].exists)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists, "A user stop must not become a provider failure.")
        attach(app, name: "controlled-stream-stopped-draft-preserved")

        // The actual WK action crosses the native bridge; this is not a direct model call.
        let regenerate = app.webViews.buttons["重新生成回复"]
        reveal(regenerate, in: app)
        regenerate.tap()
        let retry = app.buttons["assistant.retry"]
        waitHittable(retry, timeout: 25)
        XCTAssertTrue(app.staticTexts["assistant.failure"].exists)
        XCTAssertEqual(input.value as? String, draft)
        attach(app, name: "controlled-stream-two-503-attempts-visible-retry")
        retry.tap()
        wait(send, label: "发送", timeout: 25)
        XCTAssertTrue(text(app, containing: "重试后的完整回答").waitForExistence(timeout: 20))
        XCTAssertFalse(retry.exists)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists, "A successful retry must clear the previous failure.")
        XCTAssertEqual(input.value as? String, draft)
        openCitation(app, play: true)
        app.buttons["完成"].tap()
        attach(app, name: "controlled-stream-completed-with-citation")

        app.terminate(); app.launch()
        assertRestored(app, answer: "重试后的完整回答")
        openCitation(app, play: false)
        app.buttons["完成"].tap()
        attach(app, name: "controlled-stream-relaunched")
        evidence(runID, scenario: "stop-regenerate-retry", expectedHTTPRequests: 4,
                 expectedOperationRelationship: "1 != 2; 2 == 3 == 4; appAttempt[2,3]=0; appAttempt[4]=1")
    }

    func testInterruptedReplyRetriesAndExpiredCitationRemainsReadableAfterRelaunch() {
        let (app, runID) = launch("interrupted-citation")
        selectTimelineAndSend(app)
        let retry = app.buttons["assistant.retry"]
        waitHittable(retry, timeout: 25)
        XCTAssertTrue(text(app, containing: "中断前已经保留的回答").exists,
                      "A real transport failure after content must retain its partial answer.")
        XCTAssertTrue(app.staticTexts["assistant.failure"].exists)
        let input = composer(app)
        input.tap(); input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        waitForKeyboard(app)
        openCitation(app, play: false)
        app.buttons["完成"].tap()
        XCTAssertEqual(input.value as? String, draft)
        attach(app, name: "controlled-stream-interrupted-citation-retained")
        waitHittable(retry, timeout: 5); retry.tap()
        XCTAssertTrue(text(app, containing: "中断重试后的完整回答").waitForExistence(timeout: 25))
        wait(app.buttons["assistant.send"], label: "发送")
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(input.value as? String, draft)

        app.terminate()
        // This opted-in fixture invokes formal retention before the App restores its
        // conversation. It does not delete an audio file or alter the source's version.
        app.launchEnvironment["MOMO_UI_TEST_CONTROLLED_STREAM_EXPIRE_AUDIO"] = "1"
        app.launch()
        assertRestored(app, answer: "中断重试后的完整回答")
        openCitation(app, play: false)
        let play = app.buttons["source.playback"]
        let unavailable = app.staticTexts["source.audioUnavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertTrue(unavailable.label.contains("过期") || unavailable.label.contains("清理"))
        XCTAssertTrue(play.exists)
        XCTAssertFalse(play.isEnabled)
        attach(app, name: "controlled-stream-expired-source-readable-not-playable")
        let complete = app.buttons["source.openRecording"]
        waitHittable(complete, timeout: 5); complete.tap()
        XCTAssertTrue(app.navigationBars["录音"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "记录").exists)
        let discuss = app.buttons["transcript.discuss"]
        waitHittable(discuss, timeout: 5); discuss.tap()
        XCTAssertTrue(app.staticTexts["已引用这段录音"].waitForExistence(timeout: 10))
        XCTAssertEqual(composer(app).value as? String, draft)
        attach(app, name: "controlled-stream-expired-source-still-discussable")
        evidence(runID, scenario: "interrupted-citation", expectedHTTPRequests: 2,
                 expectedOperationRelationship: "1 == 2; appAttempt[1]=0; appAttempt[2]=1; no request on relaunch/reading")
    }

    private func launch(_ scenario: String) -> (XCUIApplication, String) {
        continueAfterFailure = false
        let app = XCUIApplication(), runID = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launchEnvironment["MOMO_UI_TEST_CONTROLLED_STREAM"] = scenario
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        addTeardownBlock { app.terminate() }
        let setup = XCTAttachment(string: "runID=\(runID) scenario=\(scenario) isolatedRoot=Library/Caches/MoMoAgentUITests/\(runID) ledger=controlled-stream-ledger.json; no paid or real provider flag")
        setup.name = "controlled-stream-isolation"; setup.lifetime = .keepAlways; add(setup)
        return (app, runID)
    }

    private func selectTimelineAndSend(_ app: XCUIApplication) {
        let library = app.buttons["assistant.watchStatus"]
        waitHittable(library, timeout: 20); library.tap()
        let recordings = app.buttons["assistant.watchStatus.openLibrary"]
        waitHittable(recordings, timeout: 5); recordings.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        waitHittable(row, timeout: 15); row.tap()
        XCTAssertTrue(text(app, containing: "第一段记录讨论了时间线").waitForExistence(timeout: 10))
        let discuss = app.buttons["transcript.discuss"]
        waitHittable(discuss, timeout: 5); discuss.tap()
        XCTAssertTrue(app.staticTexts["已引用这段时间"].waitForExistence(timeout: 10))
        let input = composer(app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(question)
        XCTAssertEqual(input.value as? String, question)
        waitForKeyboard(app)
        tapSendControl(app, label: "发送", name: "controlled-stream-send")
    }

    private func assertRestored(_ app: XCUIApplication, answer: String) {
        let restored = text(app, containing: answer)
        for _ in 0..<100 {
            XCTAssertFalse(app.staticTexts["assistant.welcome"].exists, "Restoring a saved thread must not show the empty home page.")
            if restored.waitForExistence(timeout: 0.2) { break }
        }
        XCTAssertTrue(restored.exists)
        XCTAssertTrue(text(app, containing: question).exists)
        XCTAssertEqual(composer(app).value as? String, draft)
        XCTAssertFalse(app.buttons["assistant.retry"].exists)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists, "A restored successful answer must not retain an earlier error banner.")
        XCTAssertEqual(app.buttons["assistant.send"].label, "发送")
    }

    private func assertCancelledBeforeBody(_ app: XCUIApplication) {
        XCTAssertTrue(text(app, containing: question).waitForExistence(timeout: 20))
        wait(app.buttons["assistant.send"], label: "发送")
        XCTAssertEqual(composer(app).value as? String, draft)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
        XCTAssertFalse(app.buttons["assistant.retry"].exists)
        XCTAssertFalse(app.staticTexts["已停止"].exists)
        XCTAssertFalse(app.webViews.buttons["复制回复"].exists)
        XCTAssertFalse(app.webViews.buttons["重新生成回复"].exists)
        XCTAssertFalse(app.webViews.links.matching(NSPredicate(format: "label == %@", "1")).firstMatch.exists)
        // Allow the document/article labels and the screen-reader-only live region,
        // but no assistant body. The ledger independently checks every response byte.
        let expectedText: Set<String> = [question, "聊天记录", "你", "助理", "已停止回复", "回复已完成"]
        let unexpected = app.webViews.staticTexts.allElementsBoundByIndex.map(\.label)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !expectedText.contains($0) }
        XCTAssertTrue(unexpected.isEmpty, "Cancelling before the first byte must not create visible answer text: \(unexpected)")
    }

    private func openCitation(_ app: XCUIApplication, play shouldPlay: Bool) {
        let citation = app.webViews.links.matching(NSPredicate(format: "label == %@", "1")).firstMatch
        reveal(citation, in: app); citation.tap()
        XCTAssertTrue(app.navigationBars["原文"].waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, containing: "记录").waitForExistence(timeout: 5))
        XCTAssertTrue(text(app, containing: "时间线").exists || text(app, containing: "播放器").exists,
                      "The citation must resolve an actual staged transcript, not arbitrary link text.")
        if shouldPlay {
            let play = app.buttons["source.playback"]
            waitHittable(play, timeout: 10); XCTAssertTrue(play.isEnabled); play.tap()
            wait(play, label: "暂停回听")
            attach(app, name: "controlled-stream-citation-native-audio-playing")
            play.tap(); wait(play, label: "继续回听")
        }
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
    }

    private func text(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            if element.isHittable { break }
            app.webViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate(format: "exists == true AND hittable == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout), .completed)
    }

    private func waitForKeyboard(_ app: XCUIApplication) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.isHittable
                && keyboard.frame.intersection(app.frame).height > 100
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 45)
        if result != .completed { attach(app, name: "controlled-stream-keyboard-not-ready") }
        XCTAssertEqual(result, .completed, "Typing must settle with an actual onscreen keyboard before the next action.")
    }

    private func tapSendControl(_ app: XCUIApplication, label: String, name: String) {
        var previous: CGRect?
        var stableSamples = 0
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let button = app.buttons["assistant.send"]
            let keyboard = app.keyboards.firstMatch
            guard button.exists, button.isHittable, button.isEnabled, button.label == label,
                  keyboard.exists, keyboard.isHittable else {
                previous = nil; stableSamples = 0
                return false
            }
            let frame = button.frame
            let keyboardFrame = keyboard.frame.intersection(app.frame)
            guard keyboardFrame.height > 100, frame.width > 0, frame.height > 0,
                  app.frame.contains(frame), frame.maxY <= keyboardFrame.minY else {
                previous = nil; stableSamples = 0
                return false
            }
            if let previous, abs(frame.minX - previous.minX) <= 0.25,
               abs(frame.minY - previous.minY) <= 0.25,
               abs(frame.width - previous.width) <= 0.25,
               abs(frame.height - previous.height) <= 0.25 {
                stableSamples += 1
            } else { stableSamples = 1 }
            previous = frame
            return stableSamples >= 3
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 15)
        attach(app, name: name + "-before-tap")
        XCTAssertEqual(result, .completed, "The current send/stop button must settle above the visible keyboard before its single tap.")
        guard result == .completed else { return }
        let button = app.buttons["assistant.send"]
        XCTAssertTrue(button.isHittable && button.isEnabled)
        XCTAssertEqual(button.label, label)
        let frame = button.frame
        XCTAssertLessThanOrEqual(frame.maxY, app.keyboards.firstMatch.frame.minY)
        if let previous {
            XCTAssertEqual(frame.minX, previous.minX, accuracy: 0.25)
            XCTAssertEqual(frame.minY, previous.minY, accuracy: 0.25)
            XCTAssertEqual(frame.width, previous.width, accuracy: 0.25)
            XCTAssertEqual(frame.height, previous.height, accuracy: 0.25)
        }
        button.tap() // One action only; no fallback coordinate or retry tap.
        attach(app, name: name + "-after-tap")
    }

    private func wait(_ element: XCUIElement, label: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "exists == true AND label == %@", label)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout), .completed)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func evidence(_ runID: String, scenario: String, expectedHTTPRequests: Int, expectedOperationRelationship: String) {
        let summary: [String: Any] = ["runID": runID, "scenario": scenario,
            "uiJourneyReachedEnd": true, "expectedHTTPRequests": expectedHTTPRequests,
            "expectedOperationRelationship": expectedOperationRelationship,
            "ledgerAndDurableSessionRequireIndependentInspection": true,
            "provider": "in-process URLProtocol synthetic SSE; no network or model quality claim"]
        let data = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "controlled-stream-ui-observations"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
