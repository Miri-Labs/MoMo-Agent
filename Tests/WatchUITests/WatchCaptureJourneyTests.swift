import XCTest
import CoreGraphics
import ImageIO

@MainActor
final class WatchCaptureJourneyTests: XCTestCase {
    func testDotFieldReachesBothScreenEdgesWithoutStartingMicrophone() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_WATCH_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["capture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(start, matches: "enabled == true AND hittable == true")
        XCTAssertEqual(start.label, "轻触以开始")
        let screenshot = app.screenshot()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let scale = Double(image.width) / app.frame.width
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let columns = (0..<image.width).filter { x in
            (image.height * 38 / 100..<image.height * 62 / 100).contains { y in
                let offset = (y * image.width + x) * 4
                return rgba[offset] > 50 && rgba[offset + 1] > 50 && rgba[offset + 2] > 50
            }
        }
        XCTAssertLessThan(Double(try XCTUnwrap(columns.first)) / scale, 4,
                          "The actual navigation screen, including its safe area, must reach the left edge.")
        XCTAssertLessThan(Double(image.width - 1 - (try XCTUnwrap(columns.last))) / scale, 4,
                          "The waveform must reach the right edge too.")
        attach(app, name: "watch-full-width-native-screen")
    }

    func testRecordingInfoExplainsAutomaticSyncWithoutManualControl() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_WATCH_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["capture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        _ = openDetails(in: app)
        XCTAssertTrue(app.staticTexts["capture.syncState"].exists)
        attach(app,name:"watch-sync-queue-summary")
        let explanation = app.staticTexts["capture.automaticSync"]
        for _ in 0..<6 {
            if explanation.isHittable { break }
            app.swipeUp()
        }
        wait(explanation, matches: "hittable == true")
        XCTAssertFalse(app.buttons["capture.retrySync"].exists)
        XCTAssertFalse(app.buttons["重新同步"].exists)
        attach(app, name: "watch-automatic-sync-info")
        closeDetails(in: app)
        wait(start, matches: "hittable == true AND enabled == true")
        XCTAssertFalse(app.buttons["capture.primary"].exists)
    }

    func testRecordMarkMuteRelaunchStartsFreshAndKeepsPendingAudio() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_WATCH_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let primary = app.buttons["capture.primary"]
        let start = app.buttons["capture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(start, matches: "enabled == true AND hittable == true")
        XCTAssertFalse(primary.exists)
        XCTAssertFalse(app.buttons["capture.mark"].exists)
        XCTAssertFalse(app.buttons["capture.transfer"].exists)
        let emptyDuration = try XCTUnwrap(openDetails(in: app).value as? String)
        closeDetails(in: app)
        attach(app, name: "watch-tap-to-start")
        start.tap()
        wait(start, matches: "exists == false")
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "持续录音中", timeout: 20)
        wait(primary, matches: "label == %@", "静音")
        let elapsed = openDetails(in: app)
        let initial = try XCTUnwrap(elapsed.value as? String)
        wait(elapsed, matches: "value != %@", initial, timeout: 10)
        closeDetails(in: app)
        attach(app, name: "watch-recording-native-capture")
        let mark = app.buttons["capture.mark"]
        mark.tap()
        wait(mark, matches: "label == %@", "已标记")
        primary.tap()
        wait(start, matches: "label == %@ AND enabled == true", "轻触以开始")
        XCTAssertFalse(primary.exists)
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "已静音")
        let pausedDuration = try XCTUnwrap(openDetails(in: app).value as? String)
        closeDetails(in: app)
        attach(app, name: "watch-paused-after-native-capture")

        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(start, matches: "label == %@ AND enabled == true", "轻触以开始")
        XCTAssertFalse(primary.exists)
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "准备录音")
        XCTAssertNotEqual(pausedDuration, emptyDuration)
        XCTAssertEqual(openDetails(in: app).value as? String, emptyDuration)
        closeDetails(in: app)
        start.tap()
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "持续录音中", timeout: 20)
        wait(primary, matches: "label == %@", "静音")
        wait(openDetails(in: app), matches: "value != %@", emptyDuration, timeout: 10)
        closeDetails(in: app)
        primary.tap()
        wait(start, matches: "label == %@ AND enabled == true", "轻触以开始")
        toolbarButton("capture.more", in: app).tap()
        XCTAssertTrue(app.buttons["capture.info"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["capture.stop"].exists)
        XCTAssertFalse(app.buttons["结束录音"].exists)
        attach(app, name: "watch-more-native-capture")
        toolbarButton("capture.more.close", in: app).tap()
        _ = openDetails(in: app)
        let pending = app.staticTexts["capture.pendingChunks"]
        wait(pending, matches: "label == %@", "2 个片段等待接收确认")
        wait(pending, matches: "hittable == true")
        attach(app, name: "watch-pending-originals-before-restart")
        closeDetails(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(start, matches: "hittable == true AND enabled == true")
        XCTAssertFalse(primary.exists)
        XCTAssertFalse(app.buttons["capture.mark"].exists)
        XCTAssertEqual(openDetails(in: app).value as? String, emptyDuration)
        wait(pending, matches: "label == %@", "2 个片段等待接收确认")
        wait(pending, matches: "hittable == true")
        attach(app, name: "watch-pending-originals-after-restart")
        closeDetails(in: app)
    }

    func testRelaunchAfterRecordingOffersTapInsteadOfHistoricalInterruption() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_WATCH_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["capture.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(start, matches: "enabled == true AND hittable == true")
        start.tap()
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "持续录音中", timeout: 20)
        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        wait(start, matches: "label == %@ AND enabled == true", "轻触以开始")
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "准备录音")
        XCTAssertFalse(app.buttons["capture.primary"].exists)
        attach(app, name: "watch-relaunch-awaiting-start-tap")
        start.tap()
        wait(app.staticTexts["capture.status"], matches: "label CONTAINS %@", "持续录音中", timeout: 20)
    }

    private func openDetails(in app: XCUIApplication) -> XCUIElement {
        toolbarButton("capture.more", in: app).tap()
        let info = app.buttons["capture.info"]
        wait(info, matches: "hittable == true AND enabled == true")
        info.tap()
        let elapsed = app.staticTexts["capture.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        wait(elapsed, matches: "hittable == true")
        return elapsed
    }

    private func closeDetails(in app: XCUIApplication) {
        let close = toolbarButton("capture.details.close", in: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        wait(close, matches: "hittable == true AND enabled == true")
        close.tap()
        wait(app.staticTexts["capture.elapsed"], matches: "exists == false")
        wait(toolbarButton("capture.more", in: app), matches: "hittable == true")
    }

    private func toolbarButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // watchOS wraps a toolbar control in a second Button with the same identifier.
        app.navigationBars.children(matching: .button).matching(identifier: identifier).element
    }

    private func wait(_ element: XCUIElement, matches format: String, _ value: String? = nil,
                      timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = value.map { NSPredicate(format: format, $0) } ?? NSPredicate(format: format)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Watch UI did not reach the expected state: \(format)", file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
