import XCTest

@MainActor
final class PhoneLocalizationTests: XCTestCase {
    func testFourLanguagesAcrossChatSettingsAndRecognitionChoices() {
        continueAfterFailure = false
        for (language, region, chat, transcripts, settings, automatic) in [
            ("zh-Hans", "zh_CN", "聊天", "转录", "设置", "自动识别"),
            ("en", "en_US", "Chat", "Transcripts", "Settings", "Auto-detect"),
            ("ja", "ja_JP", "チャット", "文字起こし", "設定", "自動検出"),
            ("ko", "ko_KR", "채팅", "음성 기록", "설정", "자동 감지")
        ] {
            let app = XCUIApplication()
            app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", region,
                                   "-iphone.firstUse.completed", "YES"]
            app.launch()
            XCTAssertTrue(app.tabBars.buttons[chat].waitForExistence(timeout: 20), language)
            XCTAssertTrue(app.tabBars.buttons[transcripts].exists, language)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                  object: app.buttons["assistant.newChat"])
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, language)
            attach(app, name: "phone-\(language)-chat")
            app.buttons["assistant.sidebar"].tap()
            let settingsButton = app.buttons["sidebar.settings"]
            let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: settingsButton)
            XCTAssertEqual(XCTWaiter.wait(for: [menuReady], timeout: 5), .completed, language)
            settingsButton.tap()
            attach(app, name: "phone-\(language)-settings-opened")
            XCTAssertTrue(app.staticTexts[settings].waitForExistence(timeout: 10), language)
            attach(app, name: "phone-\(language)-settings")
            let advanced = app.buttons["settings.advanced"]
            for _ in 0..<4 where !advanced.isHittable { app.swipeUp() }
            XCTAssertTrue(advanced.isHittable, language)
            advanced.tap()
            app.buttons["settings.speech.language"].tap()
            let auto = app.buttons["settings.speech.language.auto"]
            XCTAssertTrue(auto.waitForExistence(timeout: 10), language)
            XCTAssertTrue(auto.label.contains(automatic), language)
            for code in ["zh", "en", "ja", "ko"] {
                XCTAssertTrue(app.buttons["settings.speech.language.\(code)"].exists, "\(language): \(code)")
            }
            attach(app, name: "phone-\(language)-recognition")
            app.terminate()
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
