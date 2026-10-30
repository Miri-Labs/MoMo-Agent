import Foundation
import MoMoContracts

public struct CaptureProgress: Sendable {
    public let frames: Int64
    public let uptime: TimeInterval
    public let sealedChunkID: UUID?
    public let normalizedLevel: Float
}

/// A single detached consumer owns the resampler and AAC encoder for an entire epoch.
@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
public enum CaptureEncoder {
    public static func run(input: AudioCaptureInput, directory: URL,
                           sessionID: UUID, epochID: UUID, sourceDeviceID: UUID,
                           sourceBuild: String, sourceKind: SourceKind = .watch,
                           store: RecordingStore,
                           capacityReader: CaptureCapacityReader = .live, targetSeconds: Double = 60,
                           progress: @escaping @Sendable (CaptureProgress) async -> Void) async throws -> Int64 {
        var writer: AACSegmentWriter?
        var nextSample: Int64?
        var lastProgress: TimeInterval?
        var lastUptime: TimeInterval = 0
        var iterator = input.blocks.makeAsyncIterator()
        while true {
            let next: CapturedAudioBlock?
            do { next = try await iterator.next() }
            catch let error as AudioCaptureError {
                if let writer { _ = try await finish(writer, store: store) }
                throw error
            }
            guard let block = next else { break }
            if let expected = nextSample, let actual = block.sampleTime, expected != actual {
                if let writer { _ = try await finish(writer, store: store) }
                throw AudioCaptureError.discontinuousInput
            }
            if let time = block.sampleTime { nextSample = time + Int64(block.mono.count) }
            lastUptime = block.uptime
            if writer == nil {
                writer = try AACSegmentWriter(directory: directory, sessionID: sessionID, epochID: epochID,
                                              sourceDeviceID: sourceDeviceID, sourceBuild: sourceBuild,
                                              sourceKind: sourceKind, inputSampleRate: input.sampleRate,
                                              targetSeconds: targetSeconds,
                                              wallClockAnchor: block.wallClock, timezoneOffset: TimeZone.current.secondsFromGMT(for: block.wallClock))
            }
            guard let writer else { throw AACWriterError.invalidFormat }
            if writer.mayOpenChunk(inputFrames: block.mono.count) {
                let budget = try await store.captureCapacityBudget(targetFrames: Int64((targetSeconds * AACSegmentWriter.sampleRate).rounded()))
                writer.beforeOpeningChunk = { [weak writer] in
                    guard let writer else { throw AACWriterError.invalidFormat }
                    _ = try capacityReader.check(at: directory, budget: budget,
                        stage: writer.totalFrames == 0 ? .starting : .rotating)
                }
            }
            let chunks: [EncodedChunk]
            do { chunks = try writer.append(block.mono) }
            catch let error as CaptureCapacityError {
                for chunk in writer.sealedInCurrentOperation { try await seal(chunk, store: store) }
                await progress(CaptureProgress(frames: writer.totalFrames, uptime: block.uptime,
                    sealedChunkID: writer.sealedInCurrentOperation.last?.envelope.manifest.chunkID, normalizedLevel: 0))
                throw error
            }
            for chunk in chunks { try await seal(chunk, store: store) }
            if lastProgress == nil || block.uptime - lastProgress! >= 0.2 || !chunks.isEmpty {
                await progress(CaptureProgress(frames: writer.totalFrames, uptime: block.uptime,
                                               sealedChunkID: chunks.last?.envelope.manifest.chunkID,
                                               normalizedLevel: block.normalizedLevel))
                lastProgress = block.uptime
            }
        }
        guard let writer else { return 0 }
        let chunks: [EncodedChunk]
        do { chunks = try await finish(writer, store: store) }
        catch let error as CaptureCapacityError {
            await progress(CaptureProgress(frames: writer.totalFrames, uptime: lastUptime,
                sealedChunkID: writer.sealedInCurrentOperation.last?.envelope.manifest.chunkID, normalizedLevel: 0))
            throw error
        }
        await progress(CaptureProgress(frames: writer.totalFrames, uptime: lastUptime,
                                       sealedChunkID: chunks.last?.envelope.manifest.chunkID, normalizedLevel: 0))
        return writer.totalFrames
    }

    private static func finish(_ writer: AACSegmentWriter, store: RecordingStore) async throws -> [EncodedChunk] {
        let chunks: [EncodedChunk]
        do { chunks = try writer.finish() }
        catch let error as CaptureCapacityError {
            for chunk in writer.sealedInCurrentOperation { try await seal(chunk, store: store) }
            throw error
        }
        for chunk in chunks { try await seal(chunk, store: store) }
        return chunks
    }

    private static func seal(_ chunk: EncodedChunk, store: RecordingStore) async throws {
        _ = try await store.sealChunk(audioAt: chunk.audioURL, envelope: chunk.envelope)
        try SealedCaptureSpool.remove(chunk)
    }
}
