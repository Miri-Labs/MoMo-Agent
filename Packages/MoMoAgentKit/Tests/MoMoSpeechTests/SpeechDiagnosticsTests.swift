import Foundation
import os
import Testing
import MoMoContracts
@testable import MoMoSpeech

@Test func speechDiagnosticsRemainIsolatedAcrossCancelledAndFailedAttempts() async throws {
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
                                           tokensSHA256: String(repeating: "b", count: 64),
                                           vadSHA256: String(repeating: "c", count: 64))
    let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
    let engine = try SpeechEngine(bundle: SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest),
        configuration: SpeechConfiguration(), onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
    let cancelled = SpeechAttempt()
    cancelled.cancel()
    await #expect(throws: SpeechError.cancelled) { try await engine.prepare(inputs: [], epochClosed: true, attempt: cancelled) }
    let failed = SpeechAttempt()
    await #expect(throws: SpeechError.missingAudio) { try await engine.prepare(inputs: [], epochClosed: true, attempt: failed) }
    let values = observations.withLock { $0 }
    #expect(values.count == 2)
    #expect(values.map(\.attemptID) == [cancelled.id, failed.id])
    #expect(values.map(\.outcome) == [.cancelled, .failed])
    #expect(Set(values.map(\.operationID)).count == 2)
    #expect(values.allSatisfy { $0.modelHashedBytes == 0 && $0.audioHashedBytes == 0 && $0.nativeDecodeSeconds == 0 })
    #expect(values.first?.cancellationToOperationEndSeconds != nil)
    #expect(values.last?.cancellationToOperationEndSeconds == nil)
}

@Test func speechHashPreservesIdentityAndCountsOnlyReadBytes() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-hash-\(UUID()).bin")
    defer { do { try FileManager.default.removeItem(at: url) } catch { Issue.record(error) } }
    let data = Data((0..<131_079).map { UInt8($0 % 251) })
    try data.write(to: url, options: .withoutOverwriting)
    let attempt = SpeechAttempt()
    let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "test")
    let actual = try speechFileHash(url, attempt: attempt, recorder: recorder, model: false)
    #expect(actual == ContentHash.sha256(data))
    #expect(recorder.value.audioHashedBytes == Int64(data.count))
    #expect(recorder.value.modelHashedBytes == 0)
    #expect(recorder.value.audioHashSeconds >= 0)
}

@Test func cancelledHashDoesNotOpenMissingInput() throws {
    let attempt = SpeechAttempt()
    attempt.cancel()
    let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "test")
    #expect(throws: SpeechError.cancelled) {
        try speechFileHash(URL(fileURLWithPath: "/unused/missing-model"), attempt: attempt, recorder: recorder, model: true)
    }
    #expect(recorder.value.modelHashedBytes == 0)
}

@Test func cancellationDiagnosticsKeepFirstRequestAndExcludePreDecodeCancellation() throws {
    let attempt = SpeechAttempt()
    let start = DispatchTime.now().uptimeNanoseconds
    attempt.cancel()
    let first = try #require(attempt.cancellationUptimeNanoseconds)
    attempt.cancel()
    #expect(attempt.cancellationUptimeNanoseconds == first)
    let recorder = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id, windowID: "window", fingerprint: "test")
    recorder.nativeReturned(startedAt: start, returnedAt: first + 10, attempt: attempt)
    #expect(recorder.value.cancellationDuringNativeDecode)
    #expect(recorder.value.cancellationToNativeReturnSeconds == 10.0 / 1_000_000_000)
    let preDecode = SpeechDiagnosticRecorder(operation: .transcribe, attemptID: attempt.id, windowID: "window", fingerprint: "test")
    preDecode.nativeReturned(startedAt: first + 1, returnedAt: first + 10, attempt: attempt)
    #expect(!preDecode.value.cancellationDuringNativeDecode)
    #expect(preDecode.value.cancellationToNativeReturnSeconds == nil)
    #expect(preDecode.finished(outcome: .cancelled, attempt: attempt).outcome == .cancelled)
}
