import AVFAudio
import CoreAudioTypes
import Foundation
import Synchronization
import MoMoContracts

public enum AACWriterError: Error, Equatable {
    case invalidFormat, allocationFailed, conversionFailed, inputTooLarge
    case decodedFrameMismatch(expected: Int64, actual: Int64)
}

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
private final class ConverterInput: Sendable {
    struct State {
        let buffer: AVAudioPCMBuffer
        var available = false
    }
    let state: Mutex<State>

    init(_ buffer: sending AVAudioPCMBuffer) { state = Mutex(State(buffer: buffer)) }

    func prepare(_ mono: [Float]) {
        state.withLock { state in
            state.buffer.frameLength = AVAudioFrameCount(mono.count)
            mono.withUnsafeBufferPointer { state.buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            state.available = true
        }
    }
}

/// One serial owner. The resampler stays alive across files; only the AAC container rotates.
@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
public final class AACSegmentWriter {
    public static let sampleRate: Double = 16_000
    // Speech capture: 25% less audio than the previous 32 kbps setting; existing chunks stay intact.
    public static let bitRate = 24_000
    public private(set) var totalFrames: Int64 = 0
    private let directory: URL
    private let sessionID: UUID
    private let epochID: UUID
    private let sourceDeviceID: UUID
    private let sourceBuild: String
    private let sourceKind: SourceKind
    private let anchor: Date
    private let timezoneOffset: Int
    private let targetFrames: AVAudioFrameCount
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputBuffer: ConverterInput
    private let conversionBuffer: AVAudioPCMBuffer
    private let splitBuffer: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var chunkID: UUID?
    private var chunkFrames: AVAudioFrameCount = 0
    private var sequence: Int64 = 0
    private var finished = false
    private var draft: CaptureDraft?
    private var capacityBudgetPrepared = false
    var beforeOpeningChunk: (() throws -> Void)? {
        didSet { capacityBudgetPrepared = beforeOpeningChunk != nil }
    }
    private(set) var sealedInCurrentOperation: [EncodedChunk] = []
    // Internal fault boundary used to preserve the exact pre/post-close file state in recovery tests.
    var sealCheckpoint: ((AACSealStep, URL) throws -> Void)?

    public init(directory: URL, sessionID: UUID, epochID: UUID, sourceDeviceID: UUID,
                sourceBuild: String, sourceKind: SourceKind = .watch,
                inputSampleRate: Double, targetSeconds: Double = 60,
                wallClockAnchor: Date, timezoneOffset: Int) throws {
        guard inputSampleRate.isFinite, (8_000...192_000).contains(inputSampleRate),
              targetSeconds.isFinite, (0.01...300).contains(targetSeconds),
              let input = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: input, to: output) else { throw AACWriterError.invalidFormat }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 8_192),
              inputBuffer.floatChannelData != nil,
              let conversionBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 8_192),
              let splitBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 8_192) else {
            throw AACWriterError.allocationFailed
        }
        self.directory = directory; self.sessionID = sessionID; self.epochID = epochID
        self.sourceDeviceID = sourceDeviceID; self.sourceBuild = sourceBuild; self.sourceKind = sourceKind
        self.anchor = wallClockAnchor; self.timezoneOffset = timezoneOffset
        self.targetFrames = AVAudioFrameCount((targetSeconds * Self.sampleRate).rounded())
        self.inputFormat = input; self.converter = converter
        self.inputBuffer = ConverterInput(inputBuffer)
        self.conversionBuffer = conversionBuffer; self.splitBuffer = splitBuffer
        try RecordingFileProtection.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func append(_ mono: [Float]) throws -> [EncodedChunk] {
        sealedInCurrentOperation.removeAll(keepingCapacity: true)
        guard !finished else { throw SegmentWriterError.alreadyFinished }
        guard mono.count <= 8_192 else { throw AACWriterError.inputTooLarge }
        guard !mono.isEmpty else { return [] }
        // Conversion consumes this buffer synchronously before the serial owner can reuse it.
        inputBuffer.prepare(mono)
        return try convert(ending: false)
    }

    public func finish() throws -> [EncodedChunk] {
        sealedInCurrentOperation.removeAll(keepingCapacity: true)
        guard !finished else { throw SegmentWriterError.alreadyFinished }
        var result = try convert(ending: true)
        if chunkFrames > 0 { result.append(try closeChunk()) }
        finished = true
        return result
    }

    private func convert(ending: Bool) throws -> [EncodedChunk] {
        let output = conversionBuffer
        let pending = inputBuffer
        var result: [EncodedChunk] = []
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if let next = pending.state.withLock({ value -> AVAudioPCMBuffer? in
                    guard value.available else { return nil }
                    value.available = false
                    return value.buffer
                }) {
                    state.pointee = .haveData
                    return next
                }
                state.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if status == .error { throw AACWriterError.conversionFailed }
            if output.frameLength > 0 { result.append(contentsOf: try write(output)) }
            if status == .inputRanDry || status == .endOfStream { return result }
            guard output.frameLength > 0 else { throw AACWriterError.conversionFailed }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws -> [EncodedChunk] {
        guard let source = buffer.floatChannelData?[0] else { throw AACWriterError.invalidFormat }
        var result: [EncodedChunk] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if file == nil { try openChunk() }
            let count = min(targetFrames - chunkFrames, buffer.frameLength - offset)
            // File writes finish before the serial owner reuses either buffer.
            if offset == 0 && count == buffer.frameLength {
                try writeSlice(buffer)
            } else {
                guard let samples = splitBuffer.floatChannelData?[0] else { throw AACWriterError.allocationFailed }
                samples.update(from: source.advanced(by: Int(offset)), count: Int(count))
                splitBuffer.frameLength = count
                try writeSlice(splitBuffer)
            }
            chunkFrames += count; totalFrames += Int64(count); offset += count
            if chunkFrames == targetFrames { result.append(try closeChunk()) }
        }
        return result
    }

    private func writeSlice(_ slice: AVAudioPCMBuffer) throws {
        guard let active = file else { throw AACWriterError.invalidFormat }
        try active.write(from: slice)
    }

    private func openChunk() throws {
        try beforeOpeningChunk?()
        // The next rotation needs a fresh ledger budget. Keep the admission callback
        // available if this same converter output opens more than one small chunk.
        capacityBudgetPrepared = false
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("m4a")
        let draft = CaptureDraft(version: 1, sessionID: sessionID, epochID: epochID, chunkID: id,
                                 sourceDeviceID: sourceDeviceID, sourceBuild: sourceBuild, sourceKind: sourceKind,
                                 sequence: sequence, startFrame: totalFrames, maximumFrames: Int64(targetFrames),
                                 sampleRate: Self.sampleRate, wallClockAnchor: anchor, timezoneOffset: timezoneOffset)
        try SealedCaptureSpool.preserveDraft(draft, audio: url)
        self.draft = draft
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: Self.bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        RecordingFileProtection.apply(to: url)
        fileURL = url; chunkID = id
    }

    private func closeChunk() throws -> EncodedChunk {
        guard let url = fileURL, chunkID != nil, var draft, chunkFrames > 0 else { throw AACWriterError.invalidFormat }
        draft.closingFrameCount = Int64(chunkFrames)
        try SealedCaptureSpool.preserveDraft(draft, audio: url)
        try sealCheckpoint?(.beforeContainerClose, url)
        // ARC closes and finalizes the m4a before hashing, decoding, or handing it to the ledger.
        file = nil
        try sealCheckpoint?(.afterContainerClose, url)
        let chunk = EncodedChunk(audioURL: url, envelope: try draft.envelope(audioURL: url, verifyFullDecode: false))
        try SealedCaptureSpool.preserve(chunk)
        sealedInCurrentOperation.append(chunk)
        sequence += 1; chunkFrames = 0; fileURL = nil; chunkID = nil; self.draft = nil
        return chunk
    }

    func mayOpenChunk(inputFrames: Int) -> Bool {
        guard !capacityBudgetPrepared else { return false }
        let converted = Int64(ceil(Double(inputFrames) * Self.sampleRate / inputFormat.sampleRate))
        // Include one converter output buffer; the gate itself still reads capacity immediately before opening.
        return file == nil || Int64(targetFrames - chunkFrames) <= converted + 8_192
    }

}
