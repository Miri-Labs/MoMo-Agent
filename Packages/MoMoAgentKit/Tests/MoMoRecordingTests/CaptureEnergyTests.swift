import AVFAudio
import CSQLite
import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

@Test func capacityBudgetIsPreparedOncePerChunkInsteadOfEveryBoundaryTap() throws {
    guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try AACSegmentWriter(directory: directory, sessionID: UUID(), epochID: UUID(),
        sourceDeviceID: UUID(), sourceBuild: "energy-test", sourceKind: .fixture,
        inputSampleRate: 48_000, targetSeconds: 1, wallClockAnchor: Date(), timezoneOffset: 0)
    var budgets = 0, admissions = 0
    let samples = [Float](repeating: 0.02, count: 1_024)
    for _ in 0..<282 {
        if writer.mayOpenChunk(inputFrames: samples.count) {
            budgets += 1
            writer.beforeOpeningChunk = { admissions += 1 }
        }
        _ = try writer.append(samples)
    }
    _ = try writer.finish()
    #expect(writer.totalFrames == 96_256)
    #expect(admissions == 7, "Every new container must still check actual free space.")
    #expect(budgets <= admissions + 1, "Approaching a boundary must not repeatedly scan the ledger.")
}

@Test(arguments: [1, 2])
func hidingCaptureMeterPreservesEverySample(channels: Int) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: UInt32(channels)))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
    let samples = try #require(buffer.floatChannelData)
    for frame in 0..<1_024 {
        samples[0][frame] = frame.isMultiple(of: 2) ? 0.25 : -0.25
        if channels == 2 { samples[1][frame] = -samples[0][frame] * 0.5 }
    }
    let hidden = copyCaptureSamples(samples, channelCount: channels, frames: 1_024, meter: false)
    let visible = copyCaptureSamples(samples, channelCount: channels, frames: 1_024, meter: true)
    #expect(hidden.samples == visible.samples)
    #expect(hidden.samples.count == 1_024 && hidden.level == 0)
    #expect(visible.level == (channels == 1 ? 0.25 : 0.0625))
    samples[0][0] = 1 // The callback's buffer can be reused without changing the queued copy.
    #expect(hidden.samples[0] == (channels == 1 ? 0.25 : 0.0625))
}

@Test func unchangedTransferCursorsDoNotCommitAgain() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let observer = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
    for kind in RecordingControlKind.allCases { try await store.saveControlPosition(0, kind: kind) }
    try await store.saveFileTransferPosition(0)
    let before = try observer.rows("PRAGMA data_version") { sqlite3_column_int64($0, 0) }
    for _ in 0..<100 {
        for kind in RecordingControlKind.allCases { try await store.saveControlPosition(0, kind: kind) }
        try await store.saveFileTransferPosition(0)
    }
    let after = try observer.rows("PRAGMA data_version") { sqlite3_column_int64($0, 0) }
    #expect(after == before, "Empty queue polling must not commit unchanged cursors to the WAL.")
    for kind in RecordingControlKind.allCases { try await store.saveControlPosition(19, kind: kind) }
    try await store.saveFileTransferPosition(23)
    let reopened = try fixture.store()
    for kind in RecordingControlKind.allCases { #expect(try await reopened.controlPosition(kind: kind) == 19) }
    #expect(try await reopened.fileTransferPosition() == 23)
    try await store.saveFileTransferPosition(0)
    #expect(try await reopened.fileTransferPosition() == 0)
}
