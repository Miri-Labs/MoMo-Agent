import XCTest

/// Strict opt-in reproduction of an observed Xcode 27 XCTest keyboard-dispatch discrepancy.
/// XCTest's modified Return produced `AB`; Device Hub hardware input on the original
/// SwiftUI field produced `A\nB`. This records different outcomes, not a proven root cause.
/// The six/seven-line and relaunch checks below remain unverified by that manual result;
/// Chinese IME composition and a physical keyboard connection are outside this test's scope.
/// Set MOMO_RUN_HARDWARE_KEYBOARD_DIAGNOSTIC=1 in the test runner's environment to run it.
@MainActor
final class PhoneComposerHardwareKeyboardTests: XCTestCase {
    func testShiftReturnKeepsDraftUnsentAndSeventhLineScrollsWithinCappedComposer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MOMO_RUN_HARDWARE_KEYBOARD_DIAGNOSTIC"] == "1",
                          "Opt-in Xcode 27 keyboard-dispatch diagnostic; skipped is not a hardware-keyboard pass. Set MOMO_RUN_HARDWARE_KEYBOARD_DIAGNOSTIC=1 in the test runner environment.")
        continueAfterFailure = false
        let app = XCUIApplication()
        let runID = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        // No timeline/import/live/controlled-stream flags and no saved provider are installed.
        app.launch()
        defer { app.terminate() }
        let run = XCTAttachment(string: runID)
        run.name = "hardware-shift-return-run-id"; run.lifetime = .keepAlways; add(run)
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        focusSettledInput(input, in: app)
        selectEnglishUSKeyboard(in: app, input: input)
        input.typeText("A")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
        input.typeText("B")
        let twoLines = "A\nB"
        let twoFrame = settledInput(input, expected: twoLines, in: app)
        assertUnsent(app, input: input, expected: twoLines)
        attach(app, name: "hardware-shift-return-two-lines")

        var expected = twoLines
        for character in ["C", "D", "E", "F"] {
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
            input.typeText(character)
            expected += "\n" + character
        }
        let sixFrame = settledInput(input, expected: expected, in: app)
        XCTAssertGreaterThan(sixFrame.height, twoFrame.height + 40,
                             "The real text field must first grow; a fixed single-line control is not a capped multiline composer.")
        assertUnsent(app, input: input, expected: expected)
        attach(app, name: "hardware-shift-return-six-lines")

        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
        input.typeText("G")
        expected += "\nG"
        let sevenFrame = settledInput(input, expected: expected, in: app)
        XCTAssertEqual(sevenFrame.height, sixFrame.height, accuracy: 1,
                       "The seventh logical line stays in the six-line viewport; it must not grow the composer or lose text.")
        XCTAssertEqual(expected.components(separatedBy: "\n").count, 7)
        assertUnsent(app, input: input, expected: expected)
        attach(app, name: "hardware-shift-return-seven-lines-capped")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 15))
        let restored = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        assertUnsent(app, input: restored, expected: expected)
        attach(app, name: "hardware-shift-return-unsent-draft-relaunched")
        let data = try JSONSerialization.data(withJSONObject: [
            "runID": runID, "keyAPI": "XCUIApplication.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)",
            "twoLineDraft": twoLines, "finalDraft": expected,
            "inputHeightAtTwoLines": twoFrame.height, "inputHeightAtSixLines": sixFrame.height,
            "inputHeightAtSevenLines": sevenFrame.height,
            "unconfiguredIsolatedFixture": true, "expectedProviderRequests": 0,
            "expectedDurableUserTurns": 0, "durableRequestCountRequiresIndependentInspection": true,
            "keyboardSelectedThroughSystemMenu": "English (US)",
            "chineseIMECompositionCovered": false, "physicalKeyboardConnectionCovered": false
        ], options: [.prettyPrinted, .sortedKeys])
        let observation = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        observation.name = "hardware-shift-return-observations"
        observation.lifetime = .keepAlways
        add(observation)
    }

    private func assertUnsent(_ app: XCUIApplication, input: XCUIElement, expected: String) {
        XCTAssertEqual(input.value as? String, expected)
        // Production only renders this branch when there are no messages, streaming text,
        // sources, busy operation or failure. Do not infer durable request counts from it.
        XCTAssertTrue(app.staticTexts["assistant.welcome"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "assistant.transcript").firstMatch.exists,
                       "No user turn or answer renderer may appear from Shift+Return; the home avatar has its own WebView.")
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
        XCTAssertFalse(app.buttons["assistant.retry"].exists)
        let send = app.buttons["assistant.send"]
        waitHittable(send)
        XCTAssertEqual(send.label, "发送", "The modified Return must not start a request or turn Send into Stop.")
        XCTAssertGreaterThanOrEqual(send.frame.width + 0.000_001, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height + 0.000_001, 44)
        XCTAssertEqual(send.frame.intersection(app.frame).height, send.frame.height, accuracy: 1)
    }

    private func settledInput(_ input: XCUIElement, expected: String, in app: XCUIApplication) -> CGRect {
        var last: CGRect?
        var stable = 0
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard input.exists, input.isHittable, input.value as? String == expected else {
                last = nil; stable = 0; return false
            }
            let frame = input.frame
            guard frame.width > 0, frame.height > 0,
                  frame.intersection(app.frame).height >= frame.height - 1 else {
                last = nil; stable = 0; return false
            }
            if let previous = last, abs(previous.minY - frame.minY) <= 0.5,
               abs(previous.height - frame.height) <= 0.5 { stable += 1 }
            else { stable = 0 }
            last = frame
            return stable >= 2
        }, object: nil)
        let result = XCTWaiter.wait(for: [condition], timeout: 10)
        if result != .completed {
            let actual = input.value as? String
            let details = XCTAttachment(string: """
            expected: \(String(reflecting: expected))
            actual: \(String(reflecting: actual))
            expectedUnicodeScalars: \(expected.unicodeScalars.map(\.value))
            actualUnicodeScalars: \(actual?.unicodeScalars.map(\.value) ?? [])
            elementType: \(input.elementType.rawValue)
            frame: \(input.frame)
            appFrame: \(app.frame)
            exists: \(input.exists), hittable: \(input.isHittable), enabled: \(input.isEnabled)
            """)
            details.name = "hardware-shift-return-input-value"
            details.lifetime = .keepAlways
            add(details)
            attach(app, name: "hardware-shift-return-input-did-not-settle")
        }
        XCTAssertEqual(result, .completed, "Use a settled native text-field frame with the exact multiline draft.")
        return input.frame
    }

    private func waitHittable(_ element: XCUIElement) {
        let condition = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 10), .completed)
    }

    private func focusSettledInput(_ input: XCUIElement, in app: XCUIApplication) {
        waitForStableInputFrame(input, in: app)
        input.tap()
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 5) {
            attach(app, name: "hardware-shift-return-first-focus-not-ready")
            // The empty home can move its composer while becoming focused. Permit one
            // additional tap only after its actual frame has settled again.
            waitForStableInputFrame(input, in: app)
            input.tap()
        }
        let hasKeyboard = keyboard.waitForExistence(timeout: 10)
        if !hasKeyboard { attach(app, name: "hardware-shift-return-keyboard-not-ready") }
        XCTAssertTrue(hasKeyboard, "A real keyboard must be present before synthesizing hardware input.")
        waitForStableInputFrame(input, in: app)
        attach(app, name: "hardware-shift-return-initial-focus-ready")
    }

    private func selectEnglishUSKeyboard(in app: XCUIApplication, input: XCUIElement) {
        // The globe's value names the NEXT keyboard, not the active input language.
        // Choose the explicit system-menu item instead of treating that value as proof.
        let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                                                     ["Next keyboard", "下一个键盘", "下一键盘"])).firstMatch
        let hasGlobe = globe.waitForExistence(timeout: 5)
        if !hasGlobe { attach(app, name: "hardware-shift-return-keyboard-switch-unavailable") }
        XCTAssertTrue(hasGlobe, "The system keyboard switcher is required to select English (US) explicitly.")
        waitHittable(globe)
        globe.press(forDuration: 1)
        let englishLabels = ["English (US)", "英语（美国）", "英语(美国)", "英文（美国）", "英文(美国)"]
        let predicate = NSPredicate(format: "label IN %@", englishLabels)
        var option: XCUIElement?
        let menuReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // UIKit may represent the same menu row as a button or a text element.
            // Require a unique, actually reachable exact label within its native type.
            for query in [app.buttons, app.menuItems, app.staticTexts, app.cells, app.otherElements] {
                let matches = query.matching(predicate).allElementsBoundByIndex.filter {
                    $0.exists && $0.isEnabled && $0.isHittable
                }
                if matches.count == 1 { option = matches[0]; return true }
                if matches.count > 1 { return false }
            }
            return false
        }, object: nil)
        let menuResult = XCTWaiter.wait(for: [menuReady], timeout: 5)
        attach(app, name: "hardware-shift-return-system-keyboard-menu")
        XCTAssertEqual(menuResult, .completed,
                       "English (US) must be an explicit reachable system-menu option; do not assume an English keyboard.")
        guard let option else { XCTFail("The system menu did not expose English (US)."); return }
        let selectedLabel = option.label
        option.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !option.exists && app.keyboards.firstMatch.exists && input.exists && input.isHittable
        }, object: nil)
        let selectedResult = XCTWaiter.wait(for: [selected], timeout: 5)
        if selectedResult == .completed { waitForStableInputFrame(input, in: app) }
        attach(app, name: "hardware-shift-return-english-us-selected")
        let evidence = XCTAttachment(string: "Selected the real system-menu item: \(selectedLabel)")
        evidence.name = "hardware-shift-return-keyboard-selection"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertEqual(selectedResult, .completed, "Keyboard selection must finish before modified Return is synthesized.")
    }

    private func waitForStableInputFrame(_ input: XCUIElement, in app: XCUIApplication) {
        var previous: CGRect?
        var stable = 0
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard input.exists, input.isEnabled, input.isHittable else {
                previous = nil; stable = 0; return false
            }
            let frame = input.frame
            guard frame.width > 0, frame.height > 0,
                  frame.intersection(app.frame).height >= frame.height - 1 else {
                previous = nil; stable = 0; return false
            }
            if let previous, abs(previous.minX - frame.minX) <= 0.5,
               abs(previous.minY - frame.minY) <= 0.5,
               abs(previous.width - frame.width) <= 0.5,
               abs(previous.height - frame.height) <= 0.5 { stable += 1 }
            else { stable = 0 }
            previous = frame
            return stable >= 2
        }, object: nil)
        let result = XCTWaiter.wait(for: [condition], timeout: 10)
        if result != .completed { attach(app, name: "hardware-shift-return-initial-frame-not-stable") }
        XCTAssertEqual(result, .completed, "Focus only after the actual input frame is stable and reachable.")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
