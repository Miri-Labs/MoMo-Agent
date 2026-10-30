import XCTest
import AVFoundation
import MoMoSpeech
@testable import MoMoAgent

@MainActor
final class ChatVoiceInputTests: XCTestCase {
    func testBundledSpeechRecognizesRecordedFixture() async throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "Speech", withExtension: nil))
        let audioURL = try XCTUnwrap(Bundle.main.url(forResource: "zh", withExtension: "wav", subdirectory: "TestFixtures"))
        let audio = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(audio.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let speech = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelURL), configuration: SpeechConfiguration())
        let voice = ChatVoiceInput(permission: { true }, makeRecording: { VoiceCaptureFake(samples: samples) })
        let completed = expectation(description: "Local speech fills the composer")
        voice.start(recognize: { try await speech.dictate(samples: $0, attempt: $1) }, stopPlayback: {}) { text in
            XCTAssertEqual(text, "开放时间早上9点至下午5点。")
            completed.fulfill()
        }
        try await eventually { voice.phase == .recording }
        voice.finish()
        await fulfillment(of: [completed], timeout: 30)
        XCTAssertFalse(voice.isActive)
        XCTAssertNil(voice.failure)
    }

    func testRecognitionTimeoutRestoresComposerAndIgnoresLateResult() async throws {
        let gate = VoiceRecognitionGate()
        let voice = ChatVoiceInput(permission: { true }, makeRecording: { VoiceCaptureFake() },
                                   recognitionTimeout: .milliseconds(50))
        var draft = "原有草稿"
        voice.start(recognize: { _, _ in await gate.wait() }, stopPlayback: {}) { draft += $0 }
        try await eventually { voice.phase == .recording }
        voice.finish()
        try await eventually { await gate.waiting }
        try await eventually { !voice.isActive }
        XCTAssertEqual(voice.failure, ChatVoiceFailure.timedOut.localizedDescription)
        XCTAssertEqual(draft, "原有草稿")
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(draft, "原有草稿")
        voice.start(recognize: { _, _ in "补充" }, stopPlayback: {}) { draft += $0 }
        try await eventually { voice.phase == .recording }
        voice.finish()
        try await eventually { !voice.isActive }
        XCTAssertEqual(draft, "原有草稿补充")
        XCTAssertNil(voice.failure)
    }

    func testFinishKeepsCaptureUntilReadAndCompletesOnlyOnce() async throws {
        let capture = VoiceCaptureFake()
        let voice = ChatVoiceInput(permission: { true }, makeRecording: { capture })
        var results: [String] = []
        voice.start(recognize: { _, _ in "测试文字" }, stopPlayback: {}) { results.append($0) }
        try await eventually { voice.phase == .recording }
        voice.finish()
        voice.finish()
        try await eventually { !voice.isActive }
        XCTAssertEqual(results, ["测试文字"])
        let finished = await capture.finished, cancelled = await capture.cancelled
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(cancelled, 0, "The cancelled metering task must not stop a capture handed to transcription.")
    }

    func testCancelledRecognitionCannotWriteIntoAnotherConversation() async throws {
        let capture = VoiceCaptureFake(), gate = VoiceRecognitionGate()
        let voice = ChatVoiceInput(permission: { true }, makeRecording: { capture })
        var results: [String] = []
        voice.start(recognize: { _, _ in await gate.wait() }, stopPlayback: {}) { results.append($0) }
        try await eventually { voice.phase == .recording }
        voice.finish()
        try await eventually { await gate.waiting }
        voice.cancel()
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(voice.isActive)
    }

    func testPermissionDenialDoesNotOpenMicrophoneOrReplaceDraft() async throws {
        let capture = VoiceCaptureFake()
        let voice = ChatVoiceInput(permission: { false }, makeRecording: { capture })
        var draft = "原有草稿"
        voice.start(recognize: { _, _ in "不应识别" }, stopPlayback: {}) { draft += $0 }
        try await eventually { !voice.isActive }
        XCTAssertTrue(voice.permissionDenied)
        XCTAssertNotNil(voice.failure)
        let started = await capture.started
        XCTAssertEqual(started, 0)
        XCTAssertEqual(draft, "原有草稿")
    }

    func testLatePermissionGrantAfterCancellationDoesNotStartCapture() async throws {
        let capture = VoiceCaptureFake(), gate = VoiceRecognitionGate()
        let voice = ChatVoiceInput(permission: { _ = await gate.wait(); return true }, makeRecording: { capture })
        voice.start(recognize: { _, _ in "不应识别" }, stopPlayback: {}) { _ in XCTFail("Cancelled input completed.") }
        try await eventually { await gate.waiting }
        voice.cancel()
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        let started = await capture.started
        XCTAssertEqual(started, 0)
        XCTAssertFalse(voice.isActive)
    }

    func testNoSpeechPreservesDraftAndAllowsRetry() async throws {
        let voice = ChatVoiceInput(permission: { true }, makeRecording: { VoiceCaptureFake() })
        var draft = "原有草稿"
        voice.start(recognize: { _, _ in "" }, stopPlayback: {}) { draft += $0 }
        try await eventually { voice.phase == .recording }
        voice.finish()
        try await eventually { !voice.isActive }
        XCTAssertEqual(draft, "原有草稿")
        XCTAssertNotNil(voice.failure)
        voice.start(recognize: { _, _ in "补充" }, stopPlayback: {}) { draft += $0 }
        try await eventually { voice.phase == .recording }
        XCTAssertNil(voice.failure)
        voice.finish()
        try await eventually { !voice.isActive }
        XCTAssertEqual(draft, "原有草稿补充")
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Voice input state did not settle.")
    }
}

private actor VoiceCaptureFake: ChatVoiceRecording {
    let samples: [Float]
    var started = 0, finished = 0, cancelled = 0
    init(samples: [Float] = [0.1]) { self.samples = samples }
    func start() { started += 1 }
    func meter() -> ChatVoiceMeter { .init(level: 0.3, seconds: 1, recording: true) }
    func finish() throws -> [Float] {
        guard cancelled == 0 else { throw ChatVoiceFailure.interrupted }
        finished += 1
        return samples
    }
    func cancel() { cancelled += 1 }
}

private actor VoiceRecognitionGate {
    private var continuation: CheckedContinuation<String, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> String { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: "旧会话文字"); continuation = nil }
}
