import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoAgentClient
@testable import MoMoAgent

@MainActor
final class DailyTranscriptProjectionTests: XCTestCase {
    func testDesktopUsesRecordedDateAndOffsetInsteadOfLegacyHourOrHostZone() throws {
        let data = Data(#"{"items":[{"id":"library/session","revision":"1","recorded_at":1794760200,"total_characters":20,"windows":[{"id":"window","source_id":"library/session","source_revision":"1","recorded_at":1794760200,"end_at":1794760260,"offset":0,"end":20,"total_characters":20,"preview":"凌晨原文","natural_day":"2026-11-16","timezone_offset":28800,"date_evidence":"recorded_offset"}]}]}"#.utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let sources = try decoder.decode(SourcePage.self, from: data).items
        let eight = DesktopTranscriptSnapshot.build(sources: sources, dayStartHour: 8, version: 1)
        let all = DesktopTranscriptSnapshot.build(sources: sources, dayStartHour: 0, version: 1)
        XCTAssertEqual(eight, all)
        XCTAssertEqual(eight, DesktopTranscriptSnapshot.build(sources: sources, dayStartHour: 23, version: 1))
        XCTAssertEqual(eight.ordered.first?.logicalDayKey, "2026-11-16")
        XCTAssertEqual(eight.windowsByDayKey["2026-11-16"]?.count, 1)
        XCTAssertFalse(eight.ordered[0].rangeTimeLabel.contains("时区待确认"))
        XCTAssertEqual(eight.ordered[0].id, "window")
    }

    func testLegacySourceUsesLocalClockAndDateWithoutConfirmation() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        // 17:15 UTC is 01:15 the next day in Shanghai. Cover both old payload formats.
        let at = ISO8601DateFormatter().date(from: "2026-11-15T17:15:00Z")!.timeIntervalSince1970
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for windows in ["", #", "windows":[{"id":"window","source_id":"source","source_revision":"1","recorded_at":\#(at),"offset":0,"end":10,"total_characters":10,"timezone_offset":0,"natural_day":"2026-11-15","date_evidence":"timezone_unknown"}]"#] {
            let source = try decoder.decode(ContextSource.self, from: Data(#"{"id":"source","revision":"1","recorded_at":\#(at),"total_characters":10\#(windows)}"#.utf8))
            let item = try XCTUnwrap(DesktopTranscriptSnapshot.build(sources: [source], dayStartHour: 8, version: 1, calendar: calendar).ordered.first)
            XCTAssertEqual(item.logicalDayKey, "2026-11-16")
            XCTAssertEqual(item.rangeTimeLabel, "01:15")
            XCTAssertEqual(item.window.displayTimeZone(fallback: calendar.timeZone), calendar.timeZone)
        }
    }

    func testRecordedUTCIsPreservedAndLocalFallbackUsesHistoricalDST() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (date, expectedLocal) in [("2026-07-15T12:00:00Z", "08:00"), ("2026-11-15T12:00:00Z", "07:00")] {
            let at = ISO8601DateFormatter().date(from: date)!.timeIntervalSince1970
            for (metadata, expected) in [("", expectedLocal), (#", "timezone_offset":0,"date_evidence":"recorded_offset""#, "12:00")] {
                let source = try decoder.decode(ContextSource.self, from: Data(#"{"id":"source","revision":"1","total_characters":10,"windows":[{"id":"window","source_id":"source","source_revision":"1","recorded_at":\#(at),"offset":0,"end":10,"total_characters":10\#(metadata)}]}"#.utf8))
                let item = try XCTUnwrap(DesktopTranscriptSnapshot.build(sources: [source], dayStartHour: 8, version: 1, calendar: calendar).ordered.first)
                XCTAssertEqual(item.rangeTimeLabel, expected)
                let offset = item.window.displayTimeZone(fallback: calendar.timeZone).secondsFromGMT(for: Date(timeIntervalSince1970: at))
                XCTAssertEqual(TranscriptReadingBoundary.isEarly(Date(timeIntervalSince1970: at), offset: offset, hour: 8), expected == "07:00")
            }
        }
    }

    func testCalendarIncludesRecordedFutureDateAfterTravellingWest() {
        let today = TimelineDay(Date())
        let range = TimelineDateRange(earliestDay: today.adding(days: -2), hasLoaded: true, latestDay: today.adding(days: 1), today: today)
        XCTAssertTrue(range.canRequest(today.adding(days: 1), today: today))
        XCTAssertFalse(range.canRequest(today.adding(days: 2), today: today))
    }

    func testBackgroundAppendAndDateReturnPreserveTheAdmittedReadingAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-reading-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let day = TimelineDay(Date()).adding(days: -2)
        let firstAt = day.date(calendar: TimelineDay.calendar).addingTimeInterval(9 * 3600)
        try await add(archive, root: root, at: firstAt)
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        model.select(day)
        await model.load(day)
        let id = try XCTUnwrap(model.listWindows[day]?.first?.id)
        let admitted = try XCTUnwrap(model.cachedWindow(id))
        let span = try XCTUnwrap(admitted.window.paragraphs.first?.id)
        model.rememberReadingPosition(span, in: admitted.window, layout: admitted.layout)
        try await add(archive, root: root, at: firstAt.addingTimeInterval(3600))
        await model.refresh()
        XCTAssertEqual(model.selectedDay, day)
        let refreshed = try await model.loadWindow(id)
        let current = try XCTUnwrap(refreshed)
        XCTAssertEqual(model.readingAnchor(in: current.window, layout: current.layout), span)
        model.select(day.adding(days: -1)); await model.refresh()
        model.select(day); await model.refresh()
        let returned = try XCTUnwrap(model.cachedWindow(id))
        XCTAssertEqual(model.readingAnchor(in: returned.window, layout: returned.layout), span)
    }

    private func add(_ archive: ArchiveStore, root: URL, at: Date) async throws {
        var audio = Data("RIFF".utf8)
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { audio.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { audio.append(contentsOf: $0) } }
        u32(3236); audio.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16000); u32(32000); u16(2); u16(16); audio.append(Data("data".utf8)); u32(3200)
        audio.append(Data(repeating: 0, count: 3200))
        let manifest = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
            sourceBuild: "test", sequence: 0, frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000,
            wallClockAnchor: at, timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16000, channels: 1,
            decodedFrameCount: 1600, byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture)
        let file = root.appendingPathComponent(UUID().uuidString)
        try audio.write(to: file)
        let envelope = try ManifestEnvelope(manifest: manifest)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "daily-test")
        let ticket = try XCTUnwrap(claimed)
        _ = try await archive.commitTranscript(ticket: ticket, spans: [TranscriptSpan(chunkID: ticket.chunkID,
            frames: ticket.manifest.frames, text: "已经读到这里，后台更新和返回日期都应保留这个位置。")])
    }

    func testRefreshAndReadingPreferenceDoNotChangeSelectedDateOrClearMountedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-projection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let model = TimelineModel(archive: archive, configurationFingerprint: nil)
        let day = TimelineDay(Date()).adding(days: -2)
        model.select(day)
        await model.load(day)
        let rows = model.listWindows[day]
        model.handleDayBoundaryChanged()
        XCTAssertEqual(model.selectedDay, day)
        XCTAssertEqual(model.listWindows[day], rows)
        await model.refresh()
        XCTAssertEqual(model.selectedDay, day)
    }
}
