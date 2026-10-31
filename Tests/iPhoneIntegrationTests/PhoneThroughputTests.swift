import Foundation
import os
import UIKit
import MoMoArchive
import MoMoContracts
import MoMoSpeech
import XCTest

/// Opt-in, optimized Debug host with an isolated archive; never reads personal recordings.
@MainActor
final class PhoneThroughputTests: XCTestCase {
    func testCoreMLProcessesSparseAndDenseHoursWithinFiveMinutesEach() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Throughput acceptance requires a physical iPhone.")
#else
        guard ProcessInfo.processInfo.environment["MOMO_RUN_PHONE_THROUGHPUT"] == "1" else {
            throw XCTSkip("Set MOMO_RUN_PHONE_THROUGHPUT=1 for the physical iPhone benchmark.")
        }
        guard ProcessInfo.processInfo.environment["MOMO_UI_TEST_RUN_ID"] != nil,
              ProcessInfo.processInfo.environment["MOMO_UI_TEST_TIMELINE_FIXTURE"] == "1" else {
            return XCTFail("The test host must use its isolated archive and disable its own speech engine.")
        }
        let model = try XCTUnwrap(Bundle.main.url(forResource: "Speech", withExtension: nil))
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "zh", withExtension: "wav", subdirectory: "TestFixtures"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoThroughput-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let root = temporary.standardizedFileURL
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        print("PHONE_THROUGHPUT resources: lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled); thermal=\(ProcessInfo.processInfo.thermalState.rawValue); rootCanonical=\(temporary.path == root.path)")
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            continuousArchive: true,
            recognitionBackend: .sherpaCoreML,
            coreMLCacheDirectory: root.appendingPathComponent("model-cache"),
            speakerDirectory: model.appendingPathComponent("Speakers"),
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } }, onEvent: { _ in })
        // Prevent automatic display sleep only for this foreground benchmark; restore on all exits.
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        var rows: [HourEvidence] = []
        for dense in [false, true] {
            diagnostics.withLock { $0.removeAll(keepingCapacity: true) }
            let name = dense ? "dense-warm" : "sparse-first-load"
            let directory = root.appendingPathComponent(name)
            let capture = directory.appendingPathComponent("capture")
            let chunks = try await Task.detached(priority: .utility) {
                try dense ? PhoneTranscriptionFixture.makeDenseHour(officialWAV: audio, directory: capture)
                          : PhoneTranscriptionFixture.makeSparseHour(officialWAV: audio, directory: capture)
            }.value
            let archive = try ArchiveStore(rootURL: directory.appendingPathComponent("phone"), receiverDeviceID: UUID())
            let importStart = ProcessInfo.processInfo.systemUptime
            let received = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive,
                closeEpoch: false, sealedAt: Date().addingTimeInterval(-7_200))
            let importSeconds = ProcessInfo.processInfo.systemUptime - importStart
            let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
            let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
            let start = ProcessInfo.processInfo.systemUptime
            let report = await coordinator.runUntilIdle()
            let seconds = ProcessInfo.processInfo.systemUptime - start
            let observations = diagnostics.withLock { $0 }
            let coverage = try await archive.recordingCoverage(sessionID: received.sessionID,
                configurationFingerprint: engine.configurationFingerprint)
            let document = try await archive.readTranscript(sessionID: received.sessionID)
            let utterances = try PhoneTranscriptionFixture.hourUtteranceCount(officialWAV: audio, dense: dense)
            let expected = normalized(String(repeating: PhoneTranscriptionFixture.expectedFragments[0], count: utterances))
            // A 20-second window can contain several utterances or part of one. Compare
            // the complete ordered transcript so merging pauses cannot hide missing speech.
            let actual = normalized(document.spans.map(\.text).joined())
            let fixtureCER = Double(editDistance(actual, expected)) / Double(expected.count)
            let row = HourEvidence(workload: name, os: ProcessInfo.processInfo.operatingSystemVersionString,
                fingerprint: engine.configurationFingerprint, receivedSeconds: coverage.receivedDuration,
                processedSeconds: coverage.processedDuration, processingSeconds: seconds, importSeconds: importSeconds,
                realtimeFactor: seconds / 3_600, targetMet: seconds <= 300,
                phase: report.snapshot.phase.rawValue, failureCode: report.snapshot.failureCode,
                transcribedWindows: report.transcribedWindows, spans: document.spans.count,
                expectedUtterances: utterances, fixtureCER: fixtureCER,
                thermalStart: thermalStart, thermalEnd: ProcessInfo.processInfo.thermalState.rawValue,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                modelLoadSeconds: observations.reduce(0) { $0 + $1.modelLoadSeconds },
                nativeSeconds: observations.reduce(0) { $0 + $1.nativeDecodeSeconds },
                speakerSeconds: observations.reduce(0) { $0 + $1.speakerAnalyzeSeconds },
                audioReadSeconds: observations.reduce(0) { $0 + $1.audioReadSeconds },
                hashSeconds: observations.reduce(0) { $0 + $1.audioHashSeconds + $1.modelHashSeconds },
                vadSeconds: Double(observations.reduce(Int64(0)) { $0 + $1.vadModelFrames }) / 16_000,
                asrCoreSeconds: Double(observations.reduce(Int64(0)) { $0 + $1.coreModelFrames }) / 16_000)
            rows.append(row)
            try WireJSON.encode(rows).write(to: root.appendingPathComponent("throughput.json"), options: .atomic)
            try WireJSON.encode(observations).write(to: directory.appendingPathComponent("speech-diagnostics.json"), options: .atomic)
            attach(try WireJSON.encode(row), name: "\(name)-throughput")
            attach(try WireJSON.encode(observations), name: "\(name)-diagnostics")
            print("PHONE_THROUGHPUT \(name): \(seconds)s / 3600s; phase=\(row.phase); windows=\(row.transcribedWindows); evidence=\(root.path)")
            XCTAssertEqual(report.snapshot.phase, .idle)
            XCTAssertNil(report.snapshot.failureCode)
            XCTAssertEqual(coverage.receivedDuration, 3_600, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(coverage.processedDuration), 3_600, accuracy: 0.01)
            XCTAssertTrue(coverage.epochs.allSatisfy { $0.closedAtFrame == nil })
            XCTAssertTrue(observations.allSatisfy { $0.outcome == .completed })
            XCTAssertLessThanOrEqual(document.spans.count, report.transcribedWindows)
            XCTAssertFalse(document.spans.isEmpty)
            XCTAssertLessThan(row.fixtureCER, 0.02)
            XCTAssertEqual(String(actual).components(separatedBy: "9点至下午5点").count - 1, utterances)
            if dense { XCTAssertGreaterThan(row.asrCoreSeconds, 1_800) }
            // Remove only this generated session after its evidence is durable.
            _ = try await archive.deleteSession(id: received.sessionID)
            try FileManager.default.removeItem(at: capture)
        }
        for row in rows { XCTAssertTrue(row.targetMet, "\(row.workload): \(row.processingSeconds)s exceeds 300s") }
#endif
    }

    private func attach(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func normalized(_ text: String) -> [Character] {
        Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
    }

    private func editDistance(_ left: [Character], _ right: [Character]) -> Int {
        var previous = Array(0...right.count)
        for (i, character) in left.enumerated() {
            var current = [i + 1]
            for (j, other) in right.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }
}

private struct HourEvidence: Codable {
    let workload, os, fingerprint: String
    let receivedSeconds: Double
    let processedSeconds: Double?
    let processingSeconds, importSeconds, realtimeFactor: Double
    let targetMet: Bool
    let phase: String
    let failureCode: String?
    let transcribedWindows, spans: Int
    let expectedUtterances: Int
    let fixtureCER: Double
    let thermalStart, thermalEnd: Int
    let lowPowerMode: Bool
    let modelLoadSeconds, nativeSeconds, speakerSeconds, audioReadSeconds, hashSeconds, vadSeconds, asrCoreSeconds: Double
}
