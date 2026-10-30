import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
@testable import MoMoAgent

@MainActor
final class WatchStatusPresentationTests: XCTestCase {
    func testOnlyFreshReportsClaimCurrentRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let session = UUID(), device = UUID(), store = UUID()
        let cases: [(WatchCaptureActivity, Double, Bool, Double, String, Bool)] = [
            (.recording, 0, false, 0.1, "手表正在录音", true),
            (.paused, 0, false, 0.1, "手表已静音", false),
            (.stopped, 0, false, 0.1, "手表未在录音", false),
            (.recording, 31, false, 0.1, "上次报告：手表正在录音", false),
            (.recording, 0, true, 0.1, "上次报告：手表正在录音", false),
            (.recording, -60, false, 0.1, "上次报告：手表正在录音", false),
            (.recording, 0, false, 11, "等待手表声音采集", false),
            (.interrupted, 0, false, 0.1, "手表录音已中断", false),
            (.recording, 10, false, 0.1, "等待手表声音采集", false),
            (.failed, 0, false, 0.1, "手表录音已停止", false),
            (.preparing, 0, false, 0.1, "手表正在准备录音", false),
            (.idle, 0, false, 0.1, "手表未在录音", false)
        ]
        let indicators: [WatchStatusPresentation.Indicator] = [
            .green, .yellow, .yellow, .yellow, .yellow, .yellow,
            .yellow, .red, .yellow, .red, .yellow, .yellow
        ]
        for (index, item) in cases.enumerated() {
            let payload = try WatchCaptureStatus(receiverLibraryInstanceID: archive.libraryInstanceID,
                sessionID: session, epochID: session, activity: item.0, capturedDuration: 1, sealedDuration: 0,
                pendingChunkCount: 0, pendingBytes: 0, lastSampleFrame: 16_000, timebaseHz: 16_000, lastSampleAge: item.3)
            let snapshot = try StatusSnapshot(sourceDeviceID: device, sourceBuild: "test", sourceStoreInstanceID: store,
                revision: Int64(index + 1), sampledAt: now.addingTimeInterval(-item.1), payload: .watch(payload))
            try await archive.receiveWatchStatus(snapshot, restored: item.2, observedAt: now)
            let observation = try await archive.latestWatchStatus()
            let presentation = WatchStatusPresentation(observation: observation, now: now)
            XCTAssertEqual(presentation.title, item.4)
            XCTAssertEqual(presentation.isRecording, item.5)
            XCTAssertEqual(presentation.indicator, indicators[index])
            if index == 3 || index == 4 || index == 5 {
                XCTAssertEqual(presentation.compactTitle, "手表状态待更新")
                XCTAssertTrue(presentation.subtitle.contains("状态待更新"))
                XCTAssertTrue(presentation.subtitle.contains("以手表为准"))
            } else {
                XCTAssertEqual(presentation.compactTitle, item.4)
            }
            XCTAssertFalse(WatchStatusPresentation(observation: observation, now: now.addingTimeInterval(60)).isRecording)
            XCTAssertEqual(WatchStatusPresentation(observation: observation, now: now.addingTimeInterval(60)).indicator, .yellow)
        }
        XCTAssertEqual(WatchStatusPresentation(observation: nil, now: now).title, "等待手表状态")
        XCTAssertEqual(WatchStatusPresentation(observation: nil, now: now).compactTitle, "等待手表状态")
        XCTAssertEqual(WatchStatusPresentation(observation: nil, now: now).indicator, .yellow)
    }
}
