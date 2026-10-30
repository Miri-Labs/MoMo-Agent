import XCTest

@MainActor final class DesktopInputTests: XCTestCase {
    func testPairedTakeoverPointerKeyboardAndPermissionRecovery() async throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "5F12C378-A804-4E20-A46D-213FE37495AB"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 10) {
            app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
        }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 15) { app.buttons["onboarding.finish"].tap() }
        XCTAssertTrue(app.buttons["remote.desktop"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["remote.desktop"].tap()
        let control = app.buttons["desktop.takeControl"]
        XCTAssertTrue(control.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["在电脑上允许"].exists)
        control.tap()
        let label = app.staticTexts["desktop.controlState"]
        await wait { label.label.contains("你正在控制") }
        let desktop = app.images["desktop.preview"].firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(control.frame.minY - desktop.frame.maxY, 0)
        XCTAssertLessThan(control.frame.minY - desktop.frame.maxY, 30, "The control island belongs directly below the preview")
        desktop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try await Task.sleep(for: .milliseconds(500))
        desktop.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).doubleTap()
        XCTAssertFalse(app.buttons["desktop.tool.cursorarrow"].exists)
        XCTAssertFalse(app.buttons["desktop.tool.computermouse"].exists)
        XCTAssertFalse(app.buttons["desktop.tool.hand.draw"].exists)
        XCTAssertLessThan(control.frame.width, 150)
        desktop.twoFingerTap()
        let start = desktop.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let end = desktop.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
        app.buttons["desktop.tool.keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.typeText("hello")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        app.typeText("\n")
        let command = app.buttons["desktop.modifier.command"]
        command.tap()
        XCTAssertEqual(command.value as? String, "已选中", app.debugDescription)
        app.typeText("a")
        app.buttons["desktop.key.tab"].tap()
        capture(app, "Direct remote keyboard without a send form")
        app.buttons["desktop.tool.keyboard"].tap()
        try await Task.sleep(for: .seconds(2))
        let current = try await snapshot()
        let events = try XCTUnwrap(current["events"] as? [[String: Any]])
        let kinds = events.compactMap { $0["kind"] as? String }
        for kind in ["click", "double_click", "right_click", "mouse_down", "mouse_move", "mouse_up", "text", "key"] { XCTAssertTrue(kinds.contains(kind), "Missing \(kind): \(kinds)") }
        XCTAssertFalse(kinds.contains("drag"), "Dragging must move before touch release")
        let click = try XCTUnwrap(events.first { $0["kind"] as? String == "click" })
        XCTAssertEqual(try XCTUnwrap(click["x"] as? Double), 0.5, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(click["y"] as? Double), 0.5, accuracy: 0.03)
        XCTAssertEqual(events.filter { $0["kind"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(), "hello")
        XCTAssertTrue(events.contains { $0["key"] as? String == "backspace" })
        XCTAssertTrue(events.contains { $0["key"] as? String == "return" })
        XCTAssertTrue(events.contains { $0["key"] as? String == "a" && $0["modifiers"] as? [String] == ["command"] })
        let sequence = events.compactMap { $0["sequence"] as? Int }
        XCTAssertEqual(sequence, sequence.sorted()); XCTAssertEqual(sequence.count, Set(sequence).count)
        try await post("frame-failure", body: [:])
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(control.isEnabled)
        desktop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try await Task.sleep(for: .milliseconds(500))
        let recovered = try await snapshot()
        let recoveredEvents = try XCTUnwrap(recovered["events"] as? [[String: Any]])
        XCTAssertGreaterThan(recoveredEvents.filter { $0["kind"] as? String == "click" }.count,
                             events.filter { $0["kind"] as? String == "click" }.count)
        control.tap(); await wait { label.label.contains("MoMo 使用中") }
        app.buttons["关闭"].firstMatch.tap()
        app.buttons["remote.desktop"].tap()
        XCTAssertTrue(control.waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["在电脑上允许"].exists)
        try await post("permissions", body: ["enabled": false])
        XCTAssertTrue(app.staticTexts["首次设置远程操控"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["desktop.checkPermissions"].exists)
        XCTAssertFalse(app.buttons["在电脑上允许"].exists)
        capture(app, "System permissions distinct from durable pairing")
        try await post("permissions", body: ["enabled": true])
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        capture(app, "Paired phone ready again without another Mac approval")
        try await post("revoke", body: [:])
        XCTAssertTrue(app.buttons["desktop.rePair"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["在电脑上允许"].exists)
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in MainActor.assumeIsolated { condition() } }, object: nil)], timeout: 12)
    }
    private func snapshot() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19277/test/status")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func post(_ path: String, body: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19277/test/" + path)!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
