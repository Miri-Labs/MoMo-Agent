import Foundation
import Testing
@testable import MoMoRecording

struct CaptureEnergyLogTests {
    @Test func historyIsBoundedAndSurvivesRelaunchWithProcessIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("energy.json"), firstRun = UUID(), nextRun = UUID()
        let existing = (0..<CaptureEnergyLog.maximumSamples).map { sample(run: firstRun, tick: $0) }
        try JSONEncoder().encode(existing).write(to: url)
        let log = CaptureEnergyLog(url: url)
        try await log.append(sample(run: firstRun, tick: CaptureEnergyLog.maximumSamples))
        let reopened = CaptureEnergyLog(url: url)
        try await reopened.append(sample(run: nextRun, tick: 0))
        let saved = try JSONDecoder().decode([CaptureEnergySample].self, from: Data(contentsOf: url))
        #expect(saved.count == CaptureEnergyLog.maximumSamples)
        #expect(saved.first?.uptime == 600)
        #expect(saved.last?.runID == nextRun)
        #expect(saved.last?.batteryLevel == nil)
        #expect(saved.last?.counters.progressDeliveries == 7)
    }

    @Test func unreadableDiagnosticIsPreservedAndDoesNotBecomeRecordingData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bad = Data("not-json".utf8)
        try bad.write(to: url)
        let log = CaptureEnergyLog(url: url)
        await #expect(throws: DecodingError.self) { try await log.append(sample(run: UUID(), tick: 1)) }
        #expect(try Data(contentsOf: url) == bad)
    }

    private func sample(run: UUID, tick: Int) -> CaptureEnergySample {
        var counters = CaptureEnergyCounters(); counters.progressDeliveries = 7
        return CaptureEnergySample(runID: run, build: "test", uptime: Double(tick) * 300,
            cpuSeconds: 2, batteryLevel: nil, batteryState: 0, thermalState: 0,
            presentationSeconds: 10, activity: .recording, generation: 1, capturedFrames: 16_000,
            tapBlocks: 20, droppedBlocks: 0, pendingChunks: 0, outstandingFiles: 0, counters: counters)
    }
}
