import XCTest
import UIKit

extension XCUIApplication {
    @MainActor func personalAgentHasVisiblePixels() -> Bool {
        let frame = buttons["personalAgent.avatar"].frame
        guard frame.width > 0, let image = screenshot().image.cgImage else { return false }
        let xScale = CGFloat(image.width) / self.frame.width
        let yScale = CGFloat(image.height) / self.frame.height
        let crop = CGRect(x: frame.minX * xScale, y: frame.minY * yScale,
                          width: frame.width * xScale, height: frame.height * yScale)
        guard let avatar = image.cropping(to: crop) else { return false }
        var pixels = [UInt8](repeating: 0, count: avatar.width * avatar.height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: avatar.width, height: avatar.height,
                bitsPerComponent: 8, bytesPerRow: avatar.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(avatar, in: CGRect(x: 0, y: 0, width: avatar.width, height: avatar.height))
            let background = Int(buffer[0])
            // Check the head's center, excluding the lower-right Watch badge and the name.
            let xs = Int(Double(avatar.width) * 0.2)..<Int(Double(avatar.width) * 0.65)
            let ys = Int(Double(avatar.height) * 0.2)..<Int(Double(avatar.height) * 0.8)
            let visible = ys.reduce(0) { count, y in
                count + xs.filter { x in abs(Int(buffer[(y * avatar.width + x) * 4]) - background) > 80 }.count
            }
            return Double(visible) / Double(xs.count * ys.count) > 0.35
        }
    }
}

@MainActor
final class PhoneNavigationTests: XCTestCase {
    func testBottomTabsPreserveDraftDateAndTranscriptDetail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "1"
        app.launchEnvironment["MOMO_UI_TEST_WATCH_STATUS"] = "recording"
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        let tabs = app.tabBars.firstMatch
        let chat = tabs.buttons["聊天"]
        let transcripts = tabs.buttons["转录"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertEqual(tabs.buttons.count, 2)
        XCTAssertTrue(chat.isSelected)
        XCTAssertLessThan(chat.frame.midX, transcripts.frame.midX)
        XCTAssertGreaterThan(tabs.frame.minY, app.frame.height * 0.8)
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.personalAgentHasVisiblePixels() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed)
        attach(app, name: "bottom-tabs-chat")
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertLessThanOrEqual(input.frame.maxY, tabs.frame.minY)
        input.tap()
        input.typeText("Keep this draft while I read.")
        app.buttons["assistant.sidebar"].tap()
        XCTAssertFalse(app.buttons["sidebar.library"].exists)
        attach(app, name: "bottom-tabs-chat-history")
        app.buttons["sidebar.close"].tap()
        transcripts.tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        XCTAssertTrue(transcripts.isSelected)
        XCTAssertFalse(app.navigationBars.buttons["返回"].exists)
        attach(app, name: "bottom-tabs-transcripts")
        app.buttons["timeline.previousDay"].tap()
        XCTAssertTrue(app.buttons["timeline.datePicker"].label.contains("昨天"))
        chat.tap()
        XCTAssertEqual(input.value as? String, "Keep this draft while I read.")
        transcripts.tap()
        XCTAssertTrue(app.buttons["timeline.datePicker"].label.contains("昨天"))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["转录详情"].waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertEqual(input.value as? String, "Keep this draft while I read.")
        transcripts.tap()
        XCTAssertTrue(app.navigationBars["转录详情"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.buttons["transcript.discuss"].frame.maxY, tabs.frame.minY)
        app.buttons["transcript.discuss"].tap()
        XCTAssertTrue(app.buttons["assistant.source.remove"].waitForExistence(timeout: 5))
        XCTAssertTrue(chat.isSelected)
        XCTAssertEqual(input.value as? String, "Keep this draft while I read.")
        attach(app, name: "bottom-tabs-transcript-to-chat")
        app.terminate()
        app.launch()
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        attach(app, name: "bottom-tabs-chat-relaunch")
        transcripts.tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        attach(app, name: "bottom-tabs-transcripts-relaunch")
    }

    func testHomeComposerOpensTheSoftwareKeyboardOnFirstTapWithTheAvatarPresent() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["personalAgent.avatar"].waitForExistence(timeout: 15))
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.personalAgentHasVisiblePixels()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed,
                       "The actual home Avatar must paint; an empty accessible button is insufficient.")
        attach(app, name: "home-resident-avatar-before-input")
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(input.frame.width, 160)
        XCTAssertTrue(input.isHittable)
        input.tap()
        // Check before typeText: XCTest must not repair a failed tap by focusing the editor itself.
        let keyboard = app.keyboards.firstMatch
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && keyboard.isHittable && keyboard.frame.intersection(app.frame).height > 100
        }, object: nil)
        let result = XCTWaiter.wait(for: [opened], timeout: 8)
        attach(app, name: "home-first-tap-software-keyboard")
        XCTAssertEqual(result, .completed)
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 2)
        input.typeText("Native input stays editable.")
        XCTAssertEqual(input.value as? String, "Native input stays editable.")
        app.buttons["personalAgent.avatar"].tap()
        input.tap()
        input.typeText(" Still here.")
        XCTAssertTrue((input.value as? String)?.contains("Still here.") == true)
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
    }

    func testFirstUsePlaysAutomaticallyBeforeEnteringHome() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "NO"]
        app.launch()
        defer { app.terminate() }
        // The automatic story can finish while XCTest synchronizes with launch.
        XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["welcome.replay"].exists)
        XCTAssertFalse(app.pageIndicators.firstMatch.exists)
        attach(app, name: "landing-ready")
        app.buttons["welcome.start"].tap()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["personalAgent.avatar"].exists)
        XCTAssertTrue(app.buttons["assistant.watchStatus"].waitForExistence(timeout: 5), "The brand and Watch status return with the home navigation bar.")
        XCTAssertTrue(app.buttons["assistant.sidebar"].isHittable)
        attach(app, name: "landing-avatar-at-home")
        app.buttons["assistant.library"].tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["聊天"].tap()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 15), "Completion persists across launches.")
        XCTAssertFalse(app.staticTexts["welcome.title"].exists)
    }

    func testFirstUseCanSkipAnimation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "NO"]
        app.launch()
        defer { app.terminate() }
        let skip = app.buttons["welcome.skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 40))
        attach(app, name: "landing-skip-ready")
        XCTAssertTrue(app.buttons["welcome.start"].isHittable)
        XCTAssertFalse(app.buttons["welcome.skip"].exists)
        XCTAssertFalse(app.buttons["welcome.replay"].exists)
    }

    func testDrawerSearchAndNewConversationKeepDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 15))
        let welcome = app.staticTexts["assistant.welcome"]
        attach(app, name: "v8-home-empty")
        XCTAssertEqual(welcome.frame.midX, app.frame.midX, accuracy: 2)
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertGreaterThan(welcome.frame.minY, app.buttons["assistant.sidebar"].frame.maxY)
        XCTAssertLessThan(welcome.frame.maxY, input.frame.minY)
        input.tap()
        input.typeText("Unsent draft survives a new discussion.")
        app.buttons["assistant.sidebar"].tap()
        let drawer = app.otherElements["sidebar.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertEqual(drawer.frame.width, min(app.frame.width * 300 / 393, 340), accuracy: 2)
        attach(app, name: "v8-sidebar-drawer")
        app.buttons["sidebar.search.toggle"].tap()
        app.textFields["sidebar.search"].tap()
        app.textFields["sidebar.search"].typeText("nonexistent chat title")
        XCTAssertTrue(app.staticTexts["sidebar.search.empty"].exists)
        app.buttons["sidebar.search.clear"].tap()
        XCTAssertEqual(app.textFields["sidebar.search"].value as? String, "搜索聊天")
        app.buttons["sidebar.search.toggle"].tap()
        let newChat = app.buttons["sidebar.newChat"]
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: newChat)
        let reachability = XCTWaiter.wait(for: [reachable], timeout: 5)
        if reachability != .completed {
            attach(app, name: "v8-sidebar-action-unreachable")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "v8-sidebar-action-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(reachability, .completed)
        newChat.tap()
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Unsent draft survives a new discussion.")
        app.buttons["assistant.sidebar"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.chat.'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["sidebar.close"].tap()
        XCTAssertEqual(input.value as? String, "Unsent draft survives a new discussion.")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testComposerDraftRemainsEditableAfterNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["assistant.welcome"].waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let draft = "Help me recall what we decided today. Keep the answer brief and focus on the arrangements that still need attention."
        input.tap()
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        // Device Hub may need its software-keyboard toggle after the app takes focus.
        let visibleKeyboard = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleKeyboard], timeout: 45), .completed)
        XCTAssertGreaterThan(app.keyboards.firstMatch.frame.intersection(app.frame).height, 100,
                             "This case must exercise an onscreen software keyboard.")
        let send = app.buttons["assistant.send"]
        for _ in 0..<5 {
            if send.isHittable { break }
            app.swipeUp()
        }
        if !send.isHittable {
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "composer-action-unreachable"
            failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertTrue(send.isHittable, "The composer action must remain reachable above the keyboard.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "composer-multiline-keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["assistant.library"].tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["聊天"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, draft, "Opening local资料 must keep the unsent draft.")
        input.tap()
        let addition = " Please keep the result concise."
        input.typeText(addition)
        let edited = try XCTUnwrap(input.value as? String)
        XCTAssertEqual(edited.components(separatedBy: addition).count, 2)
        XCTAssertEqual(edited.replacingOccurrences(of: addition, with: ""), draft,
                       "Editing at the tapped cursor must preserve the entire original draft.")
        XCTAssertFalse(app.staticTexts["assistant.failure"].exists)
    }

    func testMoMoReturnsFromSettingsWithVisibleAvatarAndDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments = ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        let input = app.descendants(matching: .any).matching(identifier: "assistant.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("MoMo keeps this draft.")
        let headerY = app.buttons["personalAgent.avatar"].frame.midY
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.systemContext"].waitForExistence(timeout: 5))
        let settings = app.navigationBars.firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.buttons.firstMatch.isHittable)
        settings.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["personalAgent.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "MoMo keeps this draft.")
        XCTAssertEqual(app.buttons["personalAgent.avatar"].frame.midY, headerY, accuracy: 1)
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.personalAgentHasVisiblePixels() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 8), .completed)
        attach(app, name: "momo-returned-from-settings")
    }

    func testLibraryAndSettingsAreAvailableWithoutModelCredentials() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        let sidebar = app.buttons["assistant.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        sidebar.tap()
        XCTAssertFalse(app.buttons["sidebar.plans"].exists)
        XCTAssertFalse(app.staticTexts["计划"].exists)
        XCTAssertFalse(app.buttons["sidebar.library"].exists)
        app.buttons["sidebar.close"].tap()
        app.tabBars.buttons["转录"].tap()
        XCTAssertTrue(app.navigationBars["转录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["聊天"].tap()
        sidebar.tap()
        app.buttons["sidebar.settings"].tap()
        openProviderFromSettings(app)
        XCTAssertTrue(app.staticTexts["还没有连接模型服务"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["settings.model"].exists)
        XCTAssertFalse(app.secureTextFields["settings.apiKey"].exists)
        attach(app, name: "v8-ai-services-empty")
        app.buttons["settings.connect"].tap()
        XCTAssertTrue(app.buttons["settings.preset.deepseek"].waitForExistence(timeout: 5))
        attach(app, name: "v8-generic-provider-presets")
        app.buttons["settings.preset.deepseek"].tap()
        XCTAssertTrue(app.secureTextFields["settings.apiKey"].exists)
        XCTAssertTrue(app.textFields["settings.model"].exists)
        XCTAssertTrue(app.textFields["settings.baseURL"].exists)
        XCTAssertTrue(app.buttons["settings.save"].exists)
    }

    func testSystemAndHealthConnectionsStartDisabledWithoutRequestingPermission() {
        continueAfterFailure = false
        let app = connectionTestApp()
        defer { app.terminate() }
        openSystemConnections(in: app)
        for source in ["health", "calendar", "reminders", "alarms", "location"] {
            XCTAssertEqual(app.switches["connections.\(source).toggle"].value as? String, "0")
        }
        XCTAssertFalse(app.buttons["connections.more"].exists)
        XCTAssertFalse(app.buttons["system.history"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Opening settings must not request system access.")
        app.switches["connections.health.toggle"].tap()
        let consent = app.alerts["用于 MoMo 对话"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertTrue(consent.buttons["允许并连接"].exists)
        attach(app, name: "health-inline-consent")
        consent.buttons["取消"].tap()
        XCTAssertEqual(app.switches["connections.health.toggle"].value as? String, "0")
        XCTAssertTrue(app.navigationBars["连接与权限"].exists)
    }

    func testWebConfigurationStaysOnConnectionsAndSurvivesRestart() {
        continueAfterFailure = false
        let app = connectionTestApp()
        defer { app.terminate() }
        openSystemConnections(in: app)
        let networking = app.switches["web.enabled"]
        revealConnectionControl(networking, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: networking)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertEqual(networking.value as? String, "0")
        XCTAssertFalse(app.buttons["system.history"].exists)

        let configure = app.buttons["connections.web.configure"]
        revealConnectionControl(configure, in: app)
        configure.tap()
        let provider = app.buttons["web.connection.deepseek"]
        revealConnectionControl(provider, in: app)
        provider.tap()
        let key = app.secureTextFields["web.apiKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        revealConnectionControl(key, in: app)
        key.tap(); key.typeText("momo-ui-synthetic-only")
        // Collapsing an unsaved editor must discard its credential.
        revealConnectionControl(provider, in: app, upward: false)
        provider.tap()
        let discarded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: key)
        XCTAssertEqual(XCTWaiter.wait(for: [discarded], timeout: 5), .completed)
        provider.tap()
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertFalse((key.value as? String ?? "").contains("momo-ui-synthetic-only"))
        revealConnectionControl(key, in: app)
        key.tap(); key.typeText("momo-ui-synthetic-only")
        let save = app.buttons["web.save"]
        revealConnectionControl(save, in: app)
        save.tap()
        let configured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已配置"), object: provider)
        XCTAssertEqual(XCTWaiter.wait(for: [configured], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["连接与权限"].exists)
        XCTAssertEqual(networking.value as? String, "0", "Saving a credential must not enable networking.")
        XCTAssertFalse(app.staticTexts["web.failure"].exists)

        revealConnectionControl(provider, in: app, upward: false)
        provider.tap()
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertFalse((key.value as? String ?? "").contains("momo-ui-synthetic-only"))
        // Reopening uses the new settings revision; blank key preserves the saved credential.
        revealConnectionControl(save, in: app)
        save.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已收起"), object: provider)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["web.connectionFailure"].exists)
        app.terminate(); app.launch()
        openSystemConnections(in: app)
        revealConnectionControl(configure, in: app)
        configure.tap()
        revealConnectionControl(provider, in: app)
        XCTAssertTrue(provider.label.contains("已配置"))
        XCTAssertEqual(networking.value as? String, "0")
        provider.tap()
        let remove = app.buttons["web.remove"]
        revealConnectionControl(remove, in: app)
        remove.tap()
        let confirm = app.buttons["移除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "未配置"), object: provider)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["web.failure"].exists)
        attach(app, name: "web-services-inline-connections")
    }

    private func revealConnectionControl(_ control: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<10 {
            if control.exists && control.isHittable { return }
            if upward { app.scrollViews.firstMatch.swipeUp() } else { app.scrollViews.firstMatch.swipeDown() }
        }
        XCTAssertTrue(control.isHittable)
    }

    func testGmailSetupIsOptionalAndHasAnOfflineScreenshotGuide() {
        continueAfterFailure = false
        let app = connectionTestApp()
        defer { app.terminate() }
        openSystemConnections(in: app)
        app.buttons["connections.mail.setup"].tap()
        XCTAssertTrue(app.navigationBars["连接 Gmail"].waitForExistence(timeout: 5))
        let field = app.textFields["gmail.setup.clientID"]
        let input = field.exists ? field : app.textViews["gmail.setup.clientID"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("invalid-client")
        XCTAssertTrue(app.staticTexts["gmail.setup.invalidClientID"].exists)
        XCTAssertFalse(app.buttons["gmail.setup.connect"].isEnabled)
        app.buttons["gmail.setup.guide"].tap()
        XCTAssertTrue(app.navigationBars["Gmail 配置教程"].waitForExistence(timeout: 5))
        let firstImage = app.buttons["gmail.guide.image.gmail-guide-api"]
        XCTAssertTrue(firstImage.waitForExistence(timeout: 5))
        attach(app, name: "gmail-user-configuration-guide")
        firstImage.tap()
        let screenshot = app.images["gmail.guide.preview.image"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5))
        screenshot.pinch(withScale: 2, velocity: 1)
        app.buttons["gmail.guide.preview.done"].tap()
        XCTAssertTrue(app.navigationBars["Gmail 配置教程"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["gmail.setup.done"].tap()
        XCTAssertTrue(app.navigationBars["连接与权限"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testCalendarConnectionChoosesDestinationOnTheSamePage() throws {
        try verifyFirstConnection(source: "calendar")
    }

    func testReminderConnectionChoosesDestinationOnTheSamePage() throws {
        try verifyFirstConnection(source: "reminders")
    }

    private func verifyFirstConnection(source: String) throws {
        continueAfterFailure = false
        let app = connectionTestApp()
        defer { app.terminate() }
        openSystemConnections(in: app)
        let toggle = app.switches["connections.\(source).toggle"]
        toggle.tap()
        acceptRequestedSystemPermission(in: app, source: source)
        let destination = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connections.\(source).destination.")).firstMatch
        if destination.exists {
            XCTAssertEqual(toggle.value as? String, "0", "OS permission alone must not enable access before choosing a destination.")
            app.buttons["connections.\(source).cancel"].tap()
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.tap()
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            destination.tap()
        }
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["连接与权限"].exists)
        let savedDestination = app.buttons["connections.\(source).destination"]
        XCTAssertTrue(savedDestination.exists)
        attach(app, name: "\(source)-connected-inline")
        savedDestination.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        app.buttons["connections.\(source).cancel"].tap()
        XCTAssertEqual(toggle.value as? String, "1", "Canceling a destination edit must preserve the connection.")
        toggle.tap()
        let disconnected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 10), .completed)
        app.terminate(); app.launch()
        openSystemConnections(in: app)
        XCTAssertEqual(toggle.value as? String, "0", "Disconnect must survive relaunch.")
    }

    func testAlarmConnectionNeedsExplicitUserTap() throws {
        continueAfterFailure = false
        let app = connectionTestApp()
        defer { app.terminate() }
        openSystemConnections(in: app)
        let toggle = app.switches["connections.alarms.toggle"]
        if !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        acceptRequestedSystemPermission(in: app, source: "alarms")
        if app.buttons["connections.alarms.settings"].exists {
            XCTAssertEqual(toggle.value as? String, "0")
            throw XCTSkip("Native AlarmKit permission was denied on the isolated simulator; the refusal path was checked.")
        }
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 10), .completed)
        XCTAssertTrue(app.navigationBars["连接与权限"].exists)
        toggle.tap()
        let disconnected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 10), .completed)
    }

    private func connectionTestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        return app
    }

    private func openSystemConnections(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        let settings = app.buttons["sidebar.settings"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in settings.exists && settings.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        settings.tap()
        let entry = app.buttons["settings.systemContext"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.webServices"].exists)
        entry.tap()
        XCTAssertTrue(app.navigationBars["连接与权限"].waitForExistence(timeout: 5))
        let setup = app.buttons["connections.mail.setup"]
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: setup)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
    }

    private func acceptRequestedSystemPermission(in app: XCUIApplication, source: String) {
        let systemAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let alert = systemAlert.exists ? systemAlert : app.alerts.firstMatch
            if alert.exists {
                let allow = ["Allow Full Access", "允许完全访问", "Allow", "允许", "允许闹钟"]
                    .map { alert.buttons[$0] }.first { $0.exists }
                XCTAssertNotNil(allow, "Only the capability requested by this test may be accepted on the isolated simulator.")
                allow?.tap()
            }
            let toggle = app.switches["connections.\(source).toggle"]
            let destination = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connections.\(source).destination.")).firstMatch
            if toggle.value as? String == "1" || destination.exists || app.staticTexts["connections.\(source).error"].exists { return }
            _ = systemAlert.waitForExistence(timeout: 1)
        }
        XCTFail("The requested permission did not return to the flat connection controls.")
    }

    func testProviderRejectsAnInsecureURLBeforeSaving() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        openProviderFromSettings(app)
        app.buttons["settings.connect"].tap()
        app.buttons["settings.preset.custom"].tap()
        let model = app.textFields["settings.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap(); model.typeText("manual-model")
        let name = app.textFields["settings.connectionName"]
        let url = app.textFields["settings.baseURL"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let form = app.scrollViews.containing(.textField, identifier: "settings.connectionName").element
        name.tap()
        name.typeText("Local validation fixture")
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("http://localhost/v1")
        XCTAssertEqual(name.value as? String, "Local validation fixture")
        XCTAssertEqual(url.value as? String, "http://localhost/v1")
        let save = app.buttons["settings.save"]
        let protocolPicker = app.buttons["settings.protocol"]
        revealProviderElement(protocolPicker, in: form, app: app)
        protocolPicker.tap()
        app.buttons["Chat Completions"].tap()
        let key = app.secureTextFields["settings.apiKey"]
        revealProviderElement(key, in: form, app: app)
        key.tap()
        key.typeText("local-ui-fixture\n")
        revealProviderElement(save, in: form, app: app)
        XCTAssertTrue(save.isEnabled)
        attachProviderDiagnostics(app, name: "v8-provider-custom-address-before-validation")
        save.tap()
        let errorVisible = app.staticTexts["请填写 HTTPS API 基础地址，不包含用户名、密码、查询参数或片段。"].waitForExistence(timeout: 5)
        if !errorVisible { attachProviderDiagnostics(app, name: "v8-provider-invalid-address-failure") }
        XCTAssertTrue(errorVisible)
        XCTAssertTrue(app.navigationBars["连接服务"].exists, "Local field errors must keep the editable connection form open")
        XCTAssertFalse(app.navigationBars["选择模型"].exists)
        XCTAssertFalse(app.staticTexts["settings.saved"].exists)
        attach(app, name: "v8-invalid-address-keeps-draft")
        declineProviderPasswordOffer(app, timeout: 2, name: "v8-provider-system-password-offer")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        let backReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: back)
        let canReturn = XCTWaiter.wait(for: [backReady], timeout: 5) == .completed
        if !canReturn { attachProviderDiagnostics(app, name: "v8-provider-error-page-obstructed") }
        XCTAssertTrue(canReturn, "Declining the optional system password offer must leave the connection form navigable.")
        XCTAssertTrue(app.staticTexts["请填写 HTTPS API 基础地址，不包含用户名、密码、查询参数或片段。"].exists)
        XCTAssertFalse(app.staticTexts["settings.saved"].exists)
        back.tap()
        let keep = app.buttons["保留编辑并返回"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        XCTAssertTrue(app.navigationBars["选择服务商"].waitForExistence(timeout: 5))
        // Removing the secure field can trigger AutoFill only after the connection page is dismissed.
        declineProviderPasswordOffer(app, timeout: 5, name: "v8-provider-password-offer-after-leaving")
        let custom = app.buttons["settings.preset.custom"]
        let customReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: custom)
        let canReopen = XCTWaiter.wait(for: [customReady], timeout: 5) == .completed
        if !canReopen { attachProviderDiagnostics(app, name: "v8-provider-preset-blocked-after-leaving") }
        XCTAssertTrue(canReopen, "The actual preset must be reachable before reopening the preserved draft.")
        custom.tap()
        let reopened = name.waitForExistence(timeout: 5)
        if !reopened { attachProviderDiagnostics(app, name: "v8-provider-preserved-draft-did-not-reopen") }
        XCTAssertTrue(reopened)
        XCTAssertEqual(name.value as? String, "Local validation fixture")
        XCTAssertEqual(url.value as? String, "http://localhost/v1")
    }

    func testProviderMissingFieldsStayEditableAndPreviewUsesNormalizedMessagesBase() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        openProviderFromSettings(app)
        app.buttons["settings.connect"].tap()
        app.buttons["settings.preset.custom"].tap()
        let name = app.textFields["settings.connectionName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let form = app.scrollViews.containing(.textField, identifier: "settings.connectionName").element
        name.tap(); name.typeText("Required field fixture")
        let picker = app.buttons["settings.protocol"]
        revealProviderElement(picker, in: form, app: app)
        picker.tap(); app.buttons["Messages"].tap()
        let readModels = app.buttons["settings.readModels"]
        revealProviderElement(readModels, in: form, app: app)
        readModels.tap()
        let addressError = app.staticTexts["settings.addressError"]
        XCTAssertTrue(addressError.waitForExistence(timeout: 5))
        XCTAssertEqual(addressError.label, "请填写服务商文档提供的 API 地址。")
        XCTAssertTrue(app.navigationBars["连接服务"].exists)
        XCTAssertFalse(app.navigationBars["选择模型"].exists)
        let url = app.textFields["settings.baseURL"]
        revealProviderElement(url, in: form, app: app)
        url.tap(); url.typeText("https://provider-validation.invalid/v1")
        revealProviderElement(readModels, in: form, app: app)
        readModels.tap()
        let keyError = app.staticTexts["settings.keyError"]
        XCTAssertTrue(keyError.waitForExistence(timeout: 5))
        XCTAssertTrue(keyError.label.contains("请填写 API Key"))
        XCTAssertFalse(app.staticTexts["settings.addressError"].exists)
        XCTAssertFalse(app.staticTexts["settings.saved"].exists)
        let preview = app.staticTexts["settings.requestBaseURL"]
        revealProviderElement(preview, in: form, app: app)
        XCTAssertEqual(preview.label, "https://provider-validation.invalid/")
        XCTAssertTrue(app.staticTexts["settings.authenticationSupport"].exists)
        XCTAssertEqual(url.value as? String, "https://provider-validation.invalid/v1")
        XCTAssertEqual(name.value as? String, "Required field fixture")
        attachProviderDiagnostics(app, name: "acceptance-provider-required-fields-and-request-base")
        // No key is entered, so neither a directory request nor inference may be started.
    }

    func testProviderPresetAllowsModelFirstAndEndpointEditingOnOnePage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launchArguments += ["-iphone.firstUse.completed", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["assistant.sidebar"].waitForExistence(timeout: 15))
        app.buttons["assistant.sidebar"].tap()
        app.buttons["sidebar.settings"].tap()
        openProviderFromSettings(app)
        app.buttons["settings.connect"].tap()
        app.buttons["settings.preset.deepseek"].tap()
        let model = app.textFields["settings.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(model.isHittable, "Model entry must be visible before entering credentials")
        model.tap(); model.typeText("manual-fixture")
        let url = app.textFields["settings.baseURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertEqual(url.value as? String, "https://api.deepseek.com")
        let form = app.scrollViews.containing(.textField, identifier: "settings.connectionName").element
        revealProviderElement(url, in: form, app: app)
        url.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        url.typeText("/v1")
        XCTAssertEqual(url.value as? String, "https://api.deepseek.com/v1")
        let save = app.buttons["settings.save"]
        XCTAssertTrue(save.isHittable, "The save action must remain reachable while editing")
        save.tap()
        XCTAssertTrue(app.staticTexts["settings.keyError"].waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "manual-fixture")
        XCTAssertFalse(app.buttons["settings.connectionSettings"].exists)
        XCTAssertFalse(app.navigationBars["选择模型"].exists)
        attachProviderDiagnostics(app, name: "provider-model-first-single-form")
        XCTAssertFalse(app.staticTexts["settings.saved"].exists)
        // A missing key must prevent requests to the prefilled remote endpoint.
    }

    private func attachProviderDiagnostics(_ app: XCUIApplication, name: String) {
        attach(app, name: name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func declineProviderPasswordOffer(_ app: XCUIApplication, timeout: TimeInterval, name: String) {
        // Password AutoFill owns this optional system sheet. Decline it without saving the fixture.
        let sheet = app.sheets["保存密码？"]
        guard sheet.waitForExistence(timeout: timeout) else { return }
        attachProviderDiagnostics(app, name: name)
        let later = sheet.buttons["以后"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: later)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        later.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }

    private func openProviderFromSettings(_ app: XCUIApplication) {
        let link = app.buttons["settings.provider"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: link)
        let linkReady = XCTWaiter.wait(for: [ready], timeout: 5) == .completed
        attachProviderDiagnostics(app, name: "v8-ai-service-entry-before-tap")
        XCTAssertTrue(linkReady, "The settings navigation must finish before its AI service link can be tapped.")
        link.tap()
        let destination = app.buttons["settings.connect"]
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: destination)
        let opened = XCTWaiter.wait(for: [appeared], timeout: 5) == .completed
        if !opened { attachProviderDiagnostics(app, name: "v8-ai-service-entry-did-not-open") }
        XCTAssertTrue(opened, "One tap on the ready AI service link must open the connection page.")
        XCTAssertTrue(app.navigationBars["AI 服务"].exists)
    }

    private func revealProviderElement(_ element: XCUIElement, in form: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            // Drag the visible upper part of the actual form, above the software keyboard.
            let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
            if element.frame.maxY < app.navigationBars.element.frame.maxY {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
        }
        attachProviderDiagnostics(app, name: "v8-provider-form-element-unreachable")
        XCTAssertTrue(element.isHittable, "The custom connection form must expose its fields and actions by normal scrolling.")
    }
}
