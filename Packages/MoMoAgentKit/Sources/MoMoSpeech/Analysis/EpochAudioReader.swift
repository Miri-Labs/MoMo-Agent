@preconcurrency import AVFoundation
import Foundation
import MoMoContracts

struct SpeechInputSet {
    let inputs: [SpeechAudioInput]
    let sessionID: UUID
    let epochID: UUID
    let sampleRate: Double
    let start: Int64
    let end: Int64
    let modelFrameCount: Int64

    init(_ inputs: [SpeechAudioInput], anchor: Int64, through: Int64? = nil) throws {
        guard let first = inputs.first, anchor >= 0 else { throw SpeechError.missingAudio }
        let format = first.envelope.manifest
        var next = format.frames.start
        for input in inputs {
            let m = input.envelope.manifest
            try m.validate()
            guard input.audioURL.isFileURL, m.sessionID == format.sessionID, m.epochID == format.epochID,
                  m.sampleRate == format.sampleRate, m.timebaseHz == m.sampleRate, m.channels == format.channels,
                  m.representation == .full,
                  m.decodedFrameCount - m.primingFrames - m.paddingFrames == m.frames.count else {
                throw SpeechError.invalidAudio("epoch_format")
            }
            guard m.frames.start == next else { throw SpeechError.inputGap(expected: next, actual: m.frames.start) }
            next = m.frames.end
        }
        if let through {
            guard through > anchor, through <= next else { throw SpeechError.incompatibleCheckpoint }
            next = through
        }
        guard anchor >= format.frames.start, anchor < next else { throw SpeechError.missingAudio }
        let convertedCount = (Double(next - anchor) * 16_000 / format.sampleRate).rounded(.down)
        guard convertedCount >= 0, convertedCount < Double(Int64.max) else {
            throw SpeechError.invalidAudio("epoch_duration")
        }
        self.inputs = inputs; sessionID = format.sessionID; epochID = format.epochID
        sampleRate = format.sampleRate; start = anchor; end = next
        modelFrameCount = Int64(convertedCount)
    }

    func sourceFrame(forModelFrame frame: Int64) -> Int64 {
        let offset = (Double(frame) * sampleRate / 16_000).rounded(.up)
        if offset >= Double(end - start) { return end }
        return start + Int64(offset)
    }

    func sourceRange(_ range: FrameRange) throws -> FrameRange {
        let lower = sourceFrame(forModelFrame: range.start)
        return try FrameRange(start: lower, count: sourceFrame(forModelFrame: range.end) - lower)
    }
}

/// One converter spans physical files. Both uninterrupted and resumed work start a new reader at a committed anchor.
/// The converter invokes its input block synchronously. All access stays on SpeechEngine's serial executor.
final class EpochAudioReader: @unchecked Sendable {
    private let input: SpeechInputSet
    private var attempt: SpeechAttempt
    private var recorder: SpeechDiagnosticRecorder?
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var inputBuffer: AVAudioPCMBuffer?
    private var file: AVAudioFile?
    private var index = 0
    private var remainingFileFrames: Int64 = 0
    private var callbackError: (any Error)?
    private var emitted: Int64 = 0
    private let limit: Int64

    init(input: SpeechInputSet, attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder? = nil) throws {
        self.input = input; self.attempt = attempt
        self.recorder = recorder
        let m = input.inputs[0].envelope.manifest
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: m.sampleRate,
                                         channels: AVAudioChannelCount(m.channels), interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096) else {
            throw SpeechError.invalidAudio("converter")
        }
        self.converter = converter; self.output = output
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        limit = input.modelFrameCount
    }

    /// A continued file or retained padding is checked again; consumed prefixes are never read again.
    func continueOperation(attempt: SpeechAttempt, recorder: SpeechDiagnosticRecorder?, context: FrameRange) throws {
        self.attempt = attempt; self.recorder = recorder
        for (offset, item) in input.inputs.prefix(index).enumerated() where
            (remainingFileFrames > 0 && offset == index - 1)
            || (item.envelope.manifest.frames.start < context.end && item.envelope.manifest.frames.end > context.start) {
            try validateIdentity(item)
        }
    }

    private func validateIdentity(_ item: SpeechAudioInput) throws {
        try validateSpeechAudioIdentity(item, attempt: attempt, recorder: recorder)
    }

    func next() throws -> [Float]? {
        let start = DispatchTime.now().uptimeNanoseconds
        let hashBefore = recorder?.value.audioHashSeconds ?? 0
        defer {
            let hashSeconds = (recorder?.value.audioHashSeconds ?? 0) - hashBefore
            recorder?.value.audioReadSeconds += max(0, SpeechDiagnosticRecorder.seconds(since: start) - hashSeconds)
        }
        try attempt.checkCancellation()
        guard emitted < limit else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] requested, state in
            do {
                if let buffer = try readSource(maxFrames: requested) { state.pointee = .haveData; return buffer }
                state.pointee = .endOfStream; return nil
            } catch { callbackError = error; state.pointee = .endOfStream; return nil }
        }
        if let callbackError { throw callbackError }
        if let error { throw SpeechError.audioRead(domain: error.domain, code: error.code) }
        guard status != .error else { throw SpeechError.invalidAudio("conversion_failed") }
        let count = min(Int(output.frameLength), Int(limit - emitted))
        guard count > 0, let samples = output.floatChannelData?[0] else {
            if emitted == limit { return nil }
            throw SpeechError.invalidAudio("decoded_frame_count")
        }
        let result = Array(UnsafeBufferPointer(start: samples, count: count))
        guard result.allSatisfy(\.isFinite) else { throw SpeechError.invalidAudio("non_finite_pcm") }
        emitted += Int64(count)
        recorder?.value.convertedModelFrames += Int64(count)
        return result
    }

    private func readSource(maxFrames: AVAudioPacketCount) throws -> AVAudioPCMBuffer? {
        try attempt.checkCancellation()
        while remainingFileFrames == 0 {
            file = nil
            guard index < input.inputs.count else { return nil }
            let item = input.inputs[index]; index += 1
            let m = item.envelope.manifest
            if m.frames.end <= input.start { continue }
            guard m.frames.start < input.end else { return nil }
            try validateIdentity(item)
            let opened: AVAudioFile
            do { opened = try AVAudioFile(forReading: item.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false) }
            catch { let value = error as NSError; throw SpeechError.audioRead(domain: value.domain, code: value.code) }
            let encoded = opened.fileFormat.streamDescription.pointee
            let codecMatches: Bool
            switch m.codec {
            case .aac: codecMatches = encoded.mFormatID == kAudioFormatMPEG4AAC
            case .pcmInt16:
                codecMatches = encoded.mFormatID == kAudioFormatLinearPCM && encoded.mBitsPerChannel == 16
                    && encoded.mFormatFlags & kAudioFormatFlagIsFloat == 0
            case .pcmFloat32:
                codecMatches = encoded.mFormatID == kAudioFormatLinearPCM && encoded.mBitsPerChannel == 32
                    && encoded.mFormatFlags & kAudioFormatFlagIsFloat != 0
            }
            guard opened.length == m.decodedFrameCount,
                  codecMatches,
                  opened.processingFormat.sampleRate == m.sampleRate,
                  opened.processingFormat.channelCount == AVAudioChannelCount(m.channels) else {
                throw SpeechError.invalidAudio("decoded_format")
            }
            let skip = max(0, input.start - m.frames.start)
            opened.framePosition = m.primingFrames + skip
            remainingFileFrames = min(m.frames.end, input.end) - m.frames.start - skip
            file = opened
        }
        guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                     frameCapacity: min(maxFrames, 4_096)) else {
            throw SpeechError.invalidAudio("input_buffer")
        }
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remainingFileFrames))) }
        catch { let value = error as NSError; throw SpeechError.audioRead(domain: value.domain, code: value.code) }
        guard buffer.frameLength > 0 else { throw SpeechError.invalidAudio("truncated_audio") }
        remainingFileFrames -= Int64(buffer.frameLength)
        recorder?.value.sourceFramesRead += Int64(buffer.frameLength)
        inputBuffer = buffer
        return buffer
    }
}

func validateSpeechAudioIdentity(_ item: SpeechAudioInput, attempt: SpeechAttempt,
                                 recorder: SpeechDiagnosticRecorder?) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: item.audioURL.path)
    guard (attributes[.size] as? NSNumber)?.int64Value == item.envelope.manifest.byteCount,
          try speechFileHash(item.audioURL, attempt: attempt, recorder: recorder, model: false) == item.envelope.manifest.audioSHA256 else {
        throw SpeechError.invalidAudio("audio_identity")
    }
}
