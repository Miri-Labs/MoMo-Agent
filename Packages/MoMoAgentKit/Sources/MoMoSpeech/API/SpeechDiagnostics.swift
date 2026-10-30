import CryptoKit
import Foundation

/// One operation's counters. Timings use a monotonic clock and contain no text, paths or audio.
public struct SpeechDiagnostics: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case prepare, transcribe, warmUp, prepareDictation, dictate }
    public enum Outcome: String, Codable, Sendable { case completed, cancelled, failed }

    public let operationID: UUID
    public let attemptID: UUID
    public let operation: Operation
    public let windowID: String?
    public let configurationFingerprint: String
    public internal(set) var outcome: Outcome = .completed
    public internal(set) var failureCode: String?
    public internal(set) var queueWaitSeconds: Double = 0
    public internal(set) var elapsedSeconds: Double = 0
    public internal(set) var modelHashSeconds: Double = 0
    public internal(set) var modelHashedBytes: Int64 = 0
    public internal(set) var modelLoadSeconds: Double = 0
    public internal(set) var vadLoadSeconds: Double = 0
    public internal(set) var audioHashSeconds: Double = 0
    public internal(set) var audioHashedBytes: Int64 = 0
    /// File reads plus conversion, excluding hash time. Includes discarded prefix and read-ahead.
    public internal(set) var audioReadSeconds: Double = 0
    public internal(set) var sourceFramesRead: Int64 = 0
    public internal(set) var convertedModelFrames: Int64 = 0
    public internal(set) var preparedAudioModelFrames: Int64 = 0
    public internal(set) var analysisBackpressureSeconds: Double = 0
    public internal(set) var discardedPrefixModelFrames: Int64 = 0
    public internal(set) var discardedSuffixModelFrames: Int64 = 0
    public internal(set) var vadModelFrames: Int64 = 0
    public internal(set) var vadThreshold: Float?
    public internal(set) var vadContinuationReused: Bool?
    public internal(set) var vadReplayModelFrames: Int64?
    public internal(set) var inputModelFrames: Int64 = 0
    public internal(set) var coreModelFrames: Int64 = 0
    public internal(set) var outputWindowCount: Int = 0
    /// Archive cores selected/skipped by VAD; recorded once per prepared range, without context overlap.
    public internal(set) var selectedArchiveModelFrames: Int64?
    public internal(set) var skippedArchiveModelFrames: Int64?
    /// Actual samples submitted to native recognition, including context and excluding digital silence.
    public internal(set) var recognitionInputModelFrames: Int64?
    public internal(set) var nativeDecodeSeconds: Double = 0
    public internal(set) var coreMLPhases: CoreMLPhaseTimings?
    public internal(set) var cancellationToOperationEndSeconds: Double?
    /// Present only when cancellation was first requested while the C decode was running.
    public internal(set) var cancellationToNativeReturnSeconds: Double?
    public internal(set) var cancellationDuringNativeDecode = false
}

extension SpeechError {
    /// Fixed codes keep diagnostics useful without persisting paths or native error payloads.
    public var diagnosticCode: String {
        switch self {
        case .invalidConfiguration: "invalid_configuration"
        case .invalidModelManifest: "invalid_model_manifest"
        case .modelHashMismatch: "model_hash_mismatch"
        case .runtimeVersionMismatch: "runtime_version_mismatch"
        case .nativeInitialization: "native_initialization"
        case .nativeResult: "native_result"
        case .invalidAudio: "invalid_audio"
        case .inputGap: "input_gap"
        case .audioRead: "audio_read"
        case .incompatibleCheckpoint: "incompatible_checkpoint"
        case .incompatibleWindow: "incompatible_window"
        case .missingAudio: "missing_audio"
        case .cancelled: "cancelled"
        }
    }
}

public struct CoreMLPhaseTimings: Codable, Sendable {
    public internal(set) var inputSeconds: Double = 0
    public internal(set) var preprocessorSeconds: Double = 0
    public internal(set) var paddingSeconds: Double = 0
    public internal(set) var encoderSeconds: Double = 0
    public internal(set) var ctcSeconds: Double = 0
    public internal(set) var autoregressiveSeconds: Double?
    public internal(set) var resultSeconds: Double = 0
    public internal(set) var featureFrames: Int = 0
    public internal(set) var bucketFrames: Int = 0
    public internal(set) var ctcRejection: CoreMLCTCRejection?
    public internal(set) var rejectedFrame: Int?
    public internal(set) var rejectedToken: Int?
    public internal(set) var cpuRecovery: CoreMLCPURecovery?
}

public struct CoreMLCPURecovery: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case nonFiniteLogits, encoderRuntime }
    public internal(set) var reason: Reason
    public internal(set) var outcome: SpeechDiagnostics.Outcome = .failed
    public internal(set) var modelLoadSeconds: Double = 0
    public internal(set) var elapsedSeconds: Double = 0
}

public enum CoreMLCTCRejection: String, Codable, Sendable {
    case shape, precision, nonFinite, unknownToken, queryToken
}

/// Owned by one SpeechEngine queue operation; never reused by another attempt.
final class SpeechDiagnosticRecorder: @unchecked Sendable {
    var value: SpeechDiagnostics
    private let queuedAt = DispatchTime.now().uptimeNanoseconds

    init(operation: SpeechDiagnostics.Operation, attemptID: UUID, windowID: String?, fingerprint: String) {
        value = SpeechDiagnostics(operationID: UUID(), attemptID: attemptID, operation: operation,
                                  windowID: windowID, configurationFingerprint: fingerprint)
    }

    func started() { value.queueWaitSeconds = Self.seconds(since: queuedAt) }

    func finished(outcome: SpeechDiagnostics.Outcome, attempt: SpeechAttempt) -> SpeechDiagnostics {
        let end = DispatchTime.now().uptimeNanoseconds
        value.outcome = outcome
        value.elapsedSeconds = Self.seconds(from: queuedAt, to: end)
        if let cancelledAt = attempt.cancellationUptimeNanoseconds {
            value.cancellationToOperationEndSeconds = Self.seconds(from: cancelledAt, to: end)
        }
        return value
    }

    func nativeReturned(startedAt: UInt64, returnedAt: UInt64, attempt: SpeechAttempt) {
        value.nativeDecodeSeconds += Self.seconds(from: startedAt, to: returnedAt)
        if let cancelledAt = attempt.cancellationUptimeNanoseconds,
           cancelledAt >= startedAt, cancelledAt <= returnedAt {
            value.cancellationDuringNativeDecode = true
            value.cancellationToNativeReturnSeconds = Self.seconds(from: cancelledAt, to: returnedAt)
        }
    }

    static func seconds(since start: UInt64) -> Double {
        seconds(from: start, to: DispatchTime.now().uptimeNanoseconds)
    }

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000_000
    }
}

/// The contract's hasher has no cancellation hook. Keep this cancellable reader local to Speech.
func speechFileHash(_ url: URL, attempt: SpeechAttempt?, recorder: SpeechDiagnosticRecorder?, model: Bool) throws -> String {
    let start = DispatchTime.now().uptimeNanoseconds
    var bytes: Int64 = 0
    defer {
        if model {
            recorder?.value.modelHashSeconds += SpeechDiagnosticRecorder.seconds(since: start)
            recorder?.value.modelHashedBytes += bytes
        } else {
            recorder?.value.audioHashSeconds += SpeechDiagnosticRecorder.seconds(since: start)
            recorder?.value.audioHashedBytes += bytes
        }
    }
    try attempt?.checkCancellation()
    guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
    stream.open()
    defer { stream.close() }
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    try buffer.withUnsafeMutableBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        while true {
            try Task.checkCancellation()
            try attempt?.checkCancellation()
            let count = stream.read(base, maxLength: rawBuffer.count)
            guard count >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: rawBuffer[..<count]))
            bytes += Int64(count)
        }
    }
    try attempt?.checkCancellation()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
