import AVFoundation
import Foundation

extension ChatVoiceInput {
    convenience init() {
        self.init(permission: { await AVAudioApplication.requestRecordPermission() },
                  makeRecording: { ChatMicrophoneRecording() })
    }
}

/// All blocking AVAudioSession/file work stays off the main actor. One instance owns one capture.
actor ChatMicrophoneRecording: ChatVoiceRecording {
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var active = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            active = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDictation-\(UUID()).caf")
            file = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true
            ])
            self.recorder = recorder
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 120) else { throw ChatVoiceFailure.unavailable }
        } catch {
            cancel()
            throw error
        }
    }

    func meter() -> ChatVoiceMeter {
        guard let recorder else { return ChatVoiceMeter(level: 0, seconds: 0, recording: false) }
        recorder.updateMeters()
        return ChatVoiceMeter(level: min(1, max(0, (recorder.averagePower(forChannel: 0) + 55) / 55)),
            seconds: recorder.currentTime, recording: recorder.isRecording)
    }

    func finish() throws -> [Float] {
        recorder?.stop()
        defer { cancel() }
        guard let file else { throw ChatVoiceFailure.interrupted }
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.processingFormat.channelCount == 1, audio.processingFormat.sampleRate == 16_000,
              audio.length > 0, audio.length <= 120 * 16_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))
        else { throw ChatVoiceFailure.empty }
        try audio.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { throw ChatVoiceFailure.empty }
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if active {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            active = false
        }
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
