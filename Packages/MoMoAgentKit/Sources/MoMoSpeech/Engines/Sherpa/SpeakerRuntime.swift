import Foundation
import MoMoContracts
import MoMoSherpaBridge

private func speakerAttemptIsCancelled(_ raw: UnsafeRawPointer?) -> Int32 {
    guard let raw else { return 0 }
    let attempt = Unmanaged<SpeechAttempt>.fromOpaque(raw).takeUnretainedValue()
    return attempt.cancellationUptimeNanoseconds != nil ? 1 : 0
}

/// Queue-confined, fixed 3 s WeSpeaker on Core ML. Overlapping PyAnnote 3.0 segmentation stays on ORT CPU.
final class SpeakerRuntime: @unchecked Sendable {
    static let revision = "32fc906500b8e828c4602fd4e5caf8e38ed20e7ee7ab1b5e3719a6a4d6d4ec88"
    private static let stitchedBlockSamples = 640_000
    private let handle: OpaquePointer
    init(directory: URL, cacheRoot: URL?, attempt: SpeechAttempt) throws {
        let files = [("wespeaker-3s-coreml-fp16.onnx", Self.revision),
                     ("segmentation.int8.onnx", "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d")]
        for (file, hash) in files {
            try attempt.checkCancellation()
            guard try ContentHash.sha256(fileAt: directory.appendingPathComponent(file)) == hash else {
                throw SpeechError.modelHashMismatch(file)
            }
        }
        let cache = (cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("wespeaker-\(Self.revision)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        guard !cache.path.contains("\n"), !cache.path.contains("\r") else { throw SpeechError.invalidConfiguration }
        let config = cache.appendingPathComponent("coreml.config")
        try Data("ModelFormat=MLProgram\nMLComputeUnits=CPUAndNeuralEngine\nRequireStaticInputShapes=0\nModelCacheDirectory=\(cache.path)\nSessionConfig.session.intra_op.allow_spinning=0\nSessionConfig.session.inter_op.allow_spinning=0\n".utf8).write(to: config, options: .atomic)
        var error = [CChar](repeating: 0, count: 2048)
        guard let handle = MoMoCreateSpeakerRuntime(directory.appendingPathComponent(files[1].0).path,
            directory.appendingPathComponent(files[0].0).path, "coreml:\(config.path)", &error, error.count) else {
            throw SpeechNativeFailure(stage: .load, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        self.handle = handle
    }
    deinit { MoMoDestroySpeakerRuntime(handle) }

    func analyze(_ samples: [Float], attempt: SpeechAttempt) throws -> [SpeakerEvidence] {
        try attempt.checkCancellation()
        var result: [SpeakerEvidence] = []
        for start in stride(from: 0, to: samples.count, by: Self.stitchedBlockSamples) {
            try attempt.checkCancellation()
            let count = min(Self.stitchedBlockSamples, samples.count - start)
            var turns = [MoMoSpeakerTurn](repeating: MoMoSpeakerTurn(), count: 1024)
            var error = [CChar](repeating: 0, count: 2048)
            let written = withExtendedLifetime(attempt) {
                let context = UnsafeRawPointer(Unmanaged.passUnretained(attempt).toOpaque())
                return samples.withUnsafeBufferPointer { buffer in
                    MoMoAnalyzeSpeakers(handle, buffer.baseAddress! + start, Int32(count),
                        speakerAttemptIsCancelled, context,
                        &turns, Int32(turns.count), &error, error.count)
                }
            }
            if written == -2 { throw SpeechError.cancelled }
            guard written >= 0 else {
                throw SpeechNativeFailure(stage: .decode, detail: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
            let blockOffset = (start / Self.stitchedBlockSamples) * 3
            for var turn in turns.prefix(Int(written)) {
                let vector = withUnsafeBytes(of: &turn.embedding) { Array($0.bindMemory(to: Float.self)) }
                result.append(SpeakerEvidence(start: Double(start + Int(turn.start_sample)) / 16_000,
                    end: Double(start + Int(turn.end_sample)) / 16_000,
                    localSpeaker: turn.local_speaker < 0 ? -1 : blockOffset + Int(turn.local_speaker),
                    embedding: vector.contains(where: { $0 != 0 }) ? vector : [],
                    cleanSeconds: Double(turn.clean_seconds), modelRevision: Self.revision))
            }
        }
        try attempt.checkCancellation()
        return result
    }
}
