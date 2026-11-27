import XCTest

@MainActor
final class SettingsHierarchyTests: XCTestCase {
    /// Opt-in read-only acceptance on an already paired personal device.
    func testLiveSettingsNavigation() throws {
        guard ProcessInfo.processInfo.environment["MOMO_LIVE_SETTINGS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires an explicitly selected, already paired device")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        try inspectSettings(app)
    }

    /// Uses the loopback-only serve_chat_interaction_fixture.py manifest.
    func testSyntheticSettingsNavigation() throws {
#if targetEnvironment(simulator)
        guard let runID = ProcessInfo.processInfo.environment["MOMO_SETTINGS_FIXTURE_RUN_ID"], UUID(uuidString: runID) != nil else {
            throw XCTSkip("Requires a fresh loopback fixture manifest with the same run ID")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launch()
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) {
            app.buttons["welcome.skip"].tap(); app.buttons["welcome.start"].tap()
        }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 30) {
            app.buttons["onboarding.finish"].tap()
        }
        try inspectSettings(app, exerciseMode: true)
#else
        throw XCTSkip("Synthetic acceptance is simulator-only")
#endif
    }

    private func inspectSettings(_ app: XCUIApplication, exerciseMode: Bool = false) throws {
        if app.tabBars.buttons["聊天"].exists { app.tabBars.buttons["聊天"].tap() }
        let entry = app.buttons["remote.settings"]
        XCTAssertTrue(entry.waitForExistence(timeout: 30), app.debugDescription)
        entry.tap()
        XCTAssertTrue(app.buttons["settings.mac"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.advanced"].exists)
        XCTAssertFalse(app.segmentedControls["settings.chatMode"].exists)
        capture(app, "Settings — Home")
        app.buttons["settings.general"].tap()
        XCTAssertTrue(app.navigationBars["通用"].waitForExistence(timeout: 5))
        if exerciseMode {
            let picker = app.segmentedControls["settings.chatMode"]
            XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
            let chat = picker.buttons["聊天模式"], creator = picker.buttons["创作模式"]
            XCTAssertTrue(chat.isSelected)
            creator.tap()
            XCTAssertTrue(creator.isSelected)
            capture(app, "Settings — Creator mode")
            chat.tap()
            XCTAssertTrue(chat.isSelected)
        }
        capture(app, "Settings — General")
        back(app)
        XCTAssertFalse(app.segmentedControls["settings.chatMode"].exists)
        app.buttons["settings.mac"].tap()
        XCTAssertTrue(app.navigationBars["Mac 连接"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["remote.deviceState"].exists)
        XCTAssertFalse(app.buttons["remote.connectionDetails"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "remote.pairDevice").count, 1)
        capture(app, "Connection — inline status and network")
        app.buttons["remote.manualConnection"].tap()
        XCTAssertTrue(app.textViews["remote.connectionJSON"].waitForExistence(timeout: 10))
        // Do not capture the existing configuration or device credentials.
        back(app)
        back(app)
        XCTAssertFalse(app.buttons["settings.memories"].exists)
        if app.buttons["settings.notifications"].exists {
            app.buttons["settings.notifications"].tap()
            XCTAssertTrue(app.navigationBars["通知"].waitForExistence(timeout: 10))
            capture(app, "通知")
            back(app)
        }
        for (identifier, title) in [("health", "健康"), ("visits", "到访地点"), ("calendar", "日历"), ("reminders", "提醒事项"),
                                    ("speech.mac", "Mac 转录设置"), ("speakers", "人物与声纹"), ("storage", "储存空间")] {
            let row = app.buttons["settings." + identifier]
            for _ in 0..<5 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable, identifier)
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), title)
            if identifier == "storage" {
                XCTAssertTrue(app.descendants(matching: .any)["storage.retention.current"].waitForExistence(timeout: 30))
            }
            capture(app, title)
            if identifier == "storage" {
                app.swipeUp(); app.swipeUp()
                XCTAssertTrue(app.descendants(matching: .any)["storage.total"].waitForExistence(timeout: 10))
                capture(app, "储存空间 — 统计与设备空间")
            }
            back(app)
        }
        app.swipeDown(); app.swipeDown()
        capture(app, "Settings — after repeated navigation")
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}


@MainActor
final class MemoryReadingTests: XCTestCase {
    func testPreviewFullTextAndReversibleActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = "5F12C378-A804-4E20-A46D-213FE37495AB"
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "chat"
        app.launchEnvironment["MOMO_UI_TEST_AVATAR_UNAVAILABLE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) { app.buttons["welcome.skip"].tap() }
        if app.buttons["welcome.start"].waitForExistence(timeout: 5) { app.buttons["welcome.start"].tap() }
        if app.buttons["onboarding.finish"].waitForExistence(timeout: 10) { app.buttons["onboarding.finish"].tap() }
        XCTAssertTrue(app.buttons["remote.settings"].waitForExistence(timeout: 30))
        let memoryTab = app.tabBars.buttons["记忆"]
        XCTAssertTrue(memoryTab.waitForExistence(timeout: 10))
        memoryTab.tap()
        let row = app.buttons["remote.memoryRow.memory-layout-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(row.label.contains("0fcdf941"))
        XCTAssertTrue(row.label.contains("查看全文"))
        capture(app, "memory-list")
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .trait])
        row.tap()
        let original = app.staticTexts["remote.memoryText"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.label.contains("0fcdf941-b14c-4087-ad0e-a3eab9495fe2 v78"))
        capture(app, "memory-detail-original")
        app.buttons["remote.memoryActions"].tap()
        app.buttons["忘记这条记忆"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(original.exists)
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        let longRow = app.buttons["remote.memoryRow.memory-layout-4"]
        for _ in 0..<4 where !longRow.isHittable { app.swipeUp() }
        longRow.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.label.hasSuffix("全文末尾保留标记。"))
        let initialTextTop = original.frame.minY
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertLessThan(original.frame.minY, initialTextTop, "The long memory must actually scroll beneath the navigation bar.")
        capture(app, "memory-full-text-scroll")

    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor
final class VoiceprintUIJourneyTests: XCTestCase {
    func testVoiceprintRosterOnboardingPlaybackAndTranscriptBinding() throws {
#if targetEnvironment(simulator)
        guard let runID = ProcessInfo.processInfo.environment["MOMO_VOICEPRINT_UI_RUN_ID"],
              UUID(uuidString: runID) != nil else {
            throw XCTSkip("Requires MOMO_VOICEPRINT_UI_RUN_ID backed by local voiceprint fixture server")
        }
        continueAfterFailure = false
        let shotDir = ProcessInfo.processInfo.environment["MOMO_VOICEPRINT_SHOT_DIR"]
        func snap(_ app: XCUIApplication, _ name: String) {
            let shot = app.screenshot()
            let att = XCTAttachment(screenshot: shot)
            att.name = name; att.lifetime = .keepAlways; add(att)
            if let shotDir {
                let url = URL(fileURLWithPath: shotDir).appendingPathComponent("\(name).png")
                try? shot.pngRepresentation.write(to: url, options: .atomic)
            }
        }

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["MOMO_UI_TEST_RUN_ID"] = runID
        app.launchEnvironment["MOMO_UI_TEST_TIMELINE_FIXTURE"] = "remote"
        app.launch()
        defer { app.terminate() }

        if app.buttons["welcome.skip"].waitForExistence(timeout: 5) { app.buttons["welcome.skip"].tap() }
        if app.buttons["welcome.start"].waitForExistence(timeout: 5) { app.buttons["welcome.start"].tap() }
        if app.buttons["onboarding.voiceprint"].waitForExistence(timeout: 15) {
            snap(app, "ios_01_pairing_voiceprint_prompt")
            app.buttons["onboarding.voiceprint"].tap()
            XCTAssertTrue(app.buttons["voiceprint.onboarding.record"].waitForExistence(timeout: 8), app.debugDescription)
            snap(app, "ios_02_voiceprint_onboarding")
            app.buttons["voiceprint.onboarding.skip"].tap()
        } else if app.buttons["onboarding.finish"].waitForExistence(timeout: 15) {
            app.buttons["onboarding.finish"].tap()
        }

        // 1. Open Settings -> Mac 转录设置 & 人物与声纹
        if app.tabBars.buttons["聊天"].exists { app.tabBars.buttons["聊天"].tap() }
        let settingsBtn = app.buttons["remote.settings"]
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 25), app.debugDescription)
        settingsBtn.tap()

        let macSpeechRow = app.buttons["settings.speech.mac"]
        for _ in 0..<4 where !macSpeechRow.isHittable { app.swipeUp() }
        XCTAssertTrue(macSpeechRow.waitForExistence(timeout: 8))
        macSpeechRow.tap()
        XCTAssertTrue(app.navigationBars["Mac 转录设置"].waitForExistence(timeout: 8))
        sleep(1)
        snap(app, "ios_03_mac_speech_settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let speakersRow = app.buttons["settings.speakers"]
        for _ in 0..<4 where !speakersRow.isHittable { app.swipeUp() }
        XCTAssertTrue(speakersRow.waitForExistence(timeout: 8))
        speakersRow.tap()
        XCTAssertTrue(app.navigationBars["人物与声纹"].waitForExistence(timeout: 8))
        let alexCell = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alex")).firstMatch
        XCTAssertTrue(alexCell.waitForExistence(timeout: 10), app.debugDescription)
        sleep(1)
        snap(app, "ios_04_voiceprint_roster")

        // 2. Open owner onboarding from toolbar overflow menu
        let moreMenu = app.buttons["speaker.more.menu"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 8), app.debugDescription)
        moreMenu.tap()
        let onboardItem = app.buttons["录下我的声音"]
        XCTAssertTrue(onboardItem.waitForExistence(timeout: 8), app.debugDescription)
        onboardItem.tap()
        XCTAssertTrue(app.buttons["voiceprint.onboarding.record"].waitForExistence(timeout: 8))
        snap(app, "ios_05_owner_onboarding_sheet")
        app.buttons["关闭"].tap()

        // 3. Open Alex profile detail -> verify sample clip playback button
        XCTAssertTrue(alexCell.waitForExistence(timeout: 8), app.debugDescription)
        alexCell.tap()
        XCTAssertTrue(app.navigationBars["Alex"].waitForExistence(timeout: 8))
        let playBtn = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voiceprint.sample.play.")).firstMatch
        XCTAssertTrue(playBtn.waitForExistence(timeout: 8), app.debugDescription)
        snap(app, "ios_06_person_detail_with_clip_play")
        playBtn.tap()
        usleep(600_000)
        snap(app, "ios_07_person_detail_playing")
        app.buttons["完成"].tap()

        // 4. Trigger global rematch from toolbar overflow menu
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 8))
        moreMenu.tap()
        let rematchItem = app.buttons["重新匹配历史录音"]
        XCTAssertTrue(rematchItem.waitForExistence(timeout: 8))
        rematchItem.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已匹配")).firstMatch.waitForExistence(timeout: 10))
        snap(app, "ios_08_rematch_done")

        // 5. Navigate back to Transcripts -> open recording -> open SpeakerFeedbackMenu
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        if app.tabBars.buttons["转录"].exists {
            app.tabBars.buttons["转录"].tap()
        } else if app.buttons["assistant.library"].exists {
            app.buttons["assistant.library"].tap()
        }
        let windowBtn = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timeline.window.")).firstMatch
        if windowBtn.waitForExistence(timeout: 15) {
            windowBtn.tap()
            let speakerBtn = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker.")).firstMatch
            if speakerBtn.waitForExistence(timeout: 10) {
                snap(app, "ios_09_transcript_detail")
                speakerBtn.tap()
                XCTAssertTrue(app.switches["speaker.enroll.toggle"].waitForExistence(timeout: 8), app.debugDescription)
                snap(app, "ios_10_speaker_bind_sheet")
                app.buttons["取消"].tap()
            }
        }
#else
        throw XCTSkip("Simulator only")
#endif
    }
}
