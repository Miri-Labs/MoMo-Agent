import XCTest

@MainActor
final class WatchLocalizationTests: XCTestCase {
    func testFourLanguagesBeforeRecordingAndInMoreMenu() {
        continueAfterFailure = false
        for (language, region, start, info) in [
            ("zh-Hans", "zh_CN", "轻触以开始", "录音信息"),
            ("en", "en_US", "Tap to start", "Recording details"),
            ("ja", "ja_JP", "タップして開始", "録音情報"),
            ("ko", "ko_KR", "탭하여 시작", "녹음 정보")
        ] {
            let app = XCUIApplication()
            app.launchEnvironment["MOMO_WATCH_TEST_RUN_ID"] = UUID().uuidString
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", region]
            app.launch()
            let button = app.buttons["capture.start"]
            XCTAssertTrue(button.waitForExistence(timeout: 20), language)
            XCTAssertTrue(button.label.contains(start), language)
            attach(app, name: "watch-\(language)-ready")
            app.buttons["capture.more"].firstMatch.tap()
            XCTAssertTrue(app.buttons["capture.info"].firstMatch.waitForExistence(timeout: 10), language)
            XCTAssertEqual(app.buttons["capture.info"].firstMatch.label, info, language)
            attach(app, name: "watch-\(language)-more")
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
