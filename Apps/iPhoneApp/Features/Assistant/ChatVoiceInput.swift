import Foundation
import Observation
import MoMoSpeech

enum ChatVoiceFailure: LocalizedError, Equatable {
    case denied, unavailable, empty, interrupted, timedOut
    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "请在系统设置中允许 MoMo Agent 使用麦克风。")
        case .unavailable: String(localized: "暂时无法使用语音输入，请重试。")
        case .empty: String(localized: "没有识别到语音，请再试一次。")
        case .interrupted: String(localized: "录音已中断，请重试。")
        case .timedOut: String(localized: "语音识别超时，请重试。")
        }
    }
}

struct ChatVoiceMeter: Sendable { let level: Float; let seconds: Double; let recording: Bool }

protocol ChatVoiceRecording: Actor {
    func start() throws
    func meter() -> ChatVoiceMeter
    func finish() throws -> [Float]
    func cancel()
}

@MainActor @Observable
final class ChatVoiceInput {
    enum Phase { case idle, requesting, recording, transcribing }
    private(set) var phase: Phase = .idle
    private(set) var levels: [Float] = Array(repeating: 0, count: 28)
    private(set) var seconds = 0
    var failure: String?
    private(set) var permissionDenied = false
    var isActive: Bool { phase != .idle }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var recording: (any ChatVoiceRecording)?
    @ObservationIgnored private var recognize: (@Sendable ([Float], SpeechAttempt) async throws -> String)?
    @ObservationIgnored private var attempt: SpeechAttempt?
    @ObservationIgnored private var completion: ((String) -> Void)?
    @ObservationIgnored private let permission: () async -> Bool
    @ObservationIgnored private let makeRecording: () -> any ChatVoiceRecording
    @ObservationIgnored private let recognitionTimeout: Duration

    init(permission: @escaping () async -> Bool,
         makeRecording: @escaping () -> any ChatVoiceRecording,
         recognitionTimeout: Duration = .seconds(30)) {
        self.permission = permission; self.makeRecording = makeRecording
        self.recognitionTimeout = recognitionTimeout
    }

    func start(recognize: @escaping @Sendable ([Float], SpeechAttempt) async throws -> String,
               stopPlayback: @escaping () async -> Void,
               completion: @escaping (String) -> Void) {
        guard !isActive else { return }
        let id = UUID(), capture = makeRecording(), permission = permission, previousCleanup = cleanup
        generation = id; recording = capture; self.recognize = recognize; self.completion = completion
        failure = nil; permissionDenied = false; seconds = 0
        levels = Array(repeating: 0, count: 28)
        phase = .requesting
        work = Task { [weak self] in
            do {
                guard await permission() else { throw ChatVoiceFailure.denied }
                guard let self, self.generation == id, !Task.isCancelled else { return }
                await previousCleanup?.value
                await stopPlayback()
                try Task.checkCancellation()
                try await capture.start()
                guard self.generation == id, !Task.isCancelled else { await capture.cancel(); return }
                self.phase = .recording
                while !Task.isCancelled, self.generation == id, self.phase == .recording {
                    let meter = await capture.meter()
                    guard self.generation == id, !Task.isCancelled else { return }
                    if !meter.recording { self.finish(); return }
                    self.levels.removeFirst()
                    self.levels.append(meter.level)
                    self.seconds = Int(meter.seconds)
                    try await Task.sleep(for: .milliseconds(80))
                }
            } catch {
                guard let self, self.generation == id else { return }
                await capture.cancel()
                guard self.generation == id else { return }
                if !(error is CancellationError) {
                    self.permissionDenied = (error as? ChatVoiceFailure) == .denied
                    self.failure = error.localizedDescription
                }
                self.reset()
            }
        }
    }

    func finish() {
        guard phase == .recording, let capture = recording, let recognize else { return }
        let id = UUID(), attempt = SpeechAttempt()
        generation = id
        work?.cancel()
        self.attempt = attempt
        phase = .transcribing
        deadline = Task { [weak self, recognitionTimeout] in
            do { try await Task.sleep(for: recognitionTimeout) }
            catch { return }
            guard let self, self.generation == id, self.phase == .transcribing else { return }
            self.failure = ChatVoiceFailure.timedOut.localizedDescription
            self.cancel()
        }
        work = Task { [weak self] in
            do {
                let samples = try await capture.finish()
                try Task.checkCancellation()
                let text = try await recognize(samples, attempt)
                guard let self, self.generation == id, !Task.isCancelled else { return }
                guard !text.isEmpty else { throw ChatVoiceFailure.empty }
                let completion = self.completion
                self.reset()
                completion?(text)
            } catch {
                await capture.cancel()
                guard let self, self.generation == id else { return }
                if !(error is CancellationError), (error as? SpeechError) != .cancelled {
                    self.failure = error.localizedDescription
                }
                self.reset()
            }
        }
    }

    func cancel() {
        generation = UUID()
        work?.cancel()
        attempt?.cancel()
        if let recording { cleanup = Task { await recording.cancel() } }
        reset()
    }

    private func reset() {
        deadline?.cancel()
        deadline = nil
        phase = .idle
        work = nil; recording = nil; recognize = nil; attempt = nil; completion = nil
    }
}
