import AVFoundation
import CryptoKit
import Darwin
import Dispatch
import Foundation
import MoMoArchive
import MoMoContracts
import MoMoRecording

@MainActor
final class ContinuousReplay {
    private let options: ReplayOptions
    private let plan: ReplayPlan
    private let watch: RecordingStore
    private let phone: ArchiveStore
    private let start = ContinuousClock.now
    private var inputStart: ContinuousClock.Instant?
    private var report: ReplayReport
    private var sealed: [ManifestEnvelope] = [] // Metadata only; audio stays on disk.
    private var generator: UInt64 = 0x9E3779B97F4A7C15
    private var generatedHash = SHA256()
    private var appendedHash = SHA256()
    private var epochStarted = false
    private var epochClosed = false

    private init(options: ReplayOptions, plan: ReplayPlan) throws {
        self.options = options; self.plan = plan; report = ReplayReport(plan: plan)
        watch = try RecordingStore(rootURL: options.output.appendingPathComponent("watch"))
        phone = try ArchiveStore(rootURL: options.output.appendingPathComponent("phone"), receiverDeviceID: plan.receiverDeviceID)
    }

    static func run(options: ReplayOptions) async throws -> Int32 {
        let root = options.output
        try CaptureReplay.require(!FileManager.default.fileExists(atPath: root.path), "Output must be a new directory; existing files will not be removed.")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plan = ReplayPlan(options)
        try ReplayEvidence.save(plan, to: root.appendingPathComponent("plan.json"))
        let replay: ContinuousReplay
        do { replay = try ContinuousReplay(options: options, plan: plan) }
        catch {
            var report = ReplayReport(plan: plan)
            report.status = "failed"; report.failure = String(describing: error); report.finishedAt = Date()
            report.updateMissingCounts()
            try ReplayEvidence.save(report, to: root.appendingPathComponent("report.json"))
            throw error
        }
        let stop = ReplayStopFlag()
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            // Dispatch invokes this on its utility queue, outside this type's MainActor isolation.
            let handler: @Sendable () -> Void = { stop.request(number) }
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
        defer {
            for source in signals { source.cancel() }
            signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL)
        }
        return try await replay.execute(stop: stop)
    }

    private func execute(stop: ReplayStopFlag) async throws -> Int32 {
        try saveReport()
        print("START: pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(plan.mode) codec=\(options.codec.rawValue) frames=\(plan.plannedFrames) speed=\(options.speed)")
        do {
            try ReplayEvidence.requireDisk(options.output, remainingFrames: plan.plannedFrames)
            try sampleResources()
            try await watch.bindReceiver(deviceID: plan.receiverDeviceID, libraryInstanceID: phone.libraryInstanceID)
            try await watch.saveIntent(.recording, sessionID: plan.sessionID)
            try await watch.beginEpoch(sessionID: plan.sessionID, epochID: plan.epochID, sourceDeviceID: plan.sourceDeviceID)
            epochStarted = true
            var writer = try ReplayWriter(options: options, plan: plan, anchor: Date())
            let clock = ContinuousClock()
            let began = clock.now
            inputStart = began
            while report.appendedFrames < plan.plannedFrames && stop.receivedSignal == nil {
                let count = Int(min(Int64(ReplayOptions.blockFrames), plan.plannedFrames - report.appendedFrames))
                let endFrame = report.appendedFrames + Int64(count)
                let deadline = began.advanced(by: .seconds(Double(endFrame) / Double(ReplayOptions.sampleRate) / options.speed))
                let waitStart = clock.now
                if waitStart < deadline { try await clock.sleep(until: deadline, tolerance: .zero) }
                report.pacingWaitSeconds += waitStart.duration(to: clock.now).replaySeconds
                if stop.receivedSignal != nil { break }
                let late = max(0, deadline.duration(to: clock.now).replaySeconds)
                report.maximumPacingLatenessSeconds = max(report.maximumPacingLatenessSeconds, late)
                report.totalPacingLatenessSeconds += late
                if late > Double(count) / 16_000 / options.speed { report.blocksMoreThanOneBlockLate += 1 }
                let input = makeSamples(count: count)
                let pcm = input.withUnsafeBytes { Data($0) } // Both supported Mac architectures use little-endian Int16.
                generatedHash.update(data: pcm)
                report.generatedFrames += Int64(input.count)
                let encodeStart = clock.now
                let chunks = try writer.append(input)
                report.encodingSeconds += encodeStart.duration(to: clock.now).replaySeconds
                report.appendedFrames = endFrame
                appendedHash.update(data: pcm)
                report.inputBlocks += 1
                report.maximumInputBlockFrames = max(report.maximumInputBlockFrames, input.count)
                for chunk in chunks { try await persistAndDeliver(chunk) }
            }
            report.inputElapsedSeconds = began.duration(to: clock.now).replaySeconds
            let flushStart = clock.now
            let tail = try writer.finish()
            report.encodingSeconds += flushStart.duration(to: clock.now).replaySeconds
            for chunk in tail { try await persistAndDeliver(chunk) }
            try CaptureReplay.require(report.sealedFrames == report.appendedFrames, "Sealed frame coverage does not equal appended input frames")
            let end = try CaptureEpochEnded(sessionID: plan.sessionID, epochID: plan.epochID,
                sourceDeviceID: plan.sourceDeviceID, endFrame: report.appendedFrames, reason: .stopped)
            try await watch.recordEpochEnded(end)
            epochClosed = true
            try await phone.receiveEpochEnd(end)
            try await watch.saveIntent(.stopped, sessionID: plan.sessionID)
            if stop.receivedSignal == nil { try await verifyAfterReopen(stop: stop) }
            report.status = stop.receivedSignal == nil ? "completed" : "interrupted"
            if report.status == "completed" {
                try CaptureReplay.require(report.appendedFrames == plan.plannedFrames && report.finalVerificationComplete,
                    "Completed run lacks all planned input frames or final verification")
            }
        } catch {
            report.status = "failed"; report.failure = String(describing: error)
            if epochStarted && !epochClosed {
                do {
                    _ = try await watch.recordEpochInterruption(sessionID: plan.sessionID, epochID: plan.epochID,
                        sourceDeviceID: plan.sourceDeviceID, lastObservedFrame: report.appendedFrames, reason: .failed)
                } catch { report.failure = "\(report.failure ?? "Replay failed"); interruption record: \(error)" }
            }
        }
        report.terminationSignal = stop.receivedSignal
        if report.inputElapsedSeconds == 0, let inputStart { report.inputElapsedSeconds = inputStart.duration(to: .now).replaySeconds }
        do {
            report.pendingWatchChunks = try await watch.pendingChunkCount()
            report.pendingInboxFiles = try phone.inbox.pendingItems().count
            if report.receivedChunks > 0 {
                let coverage = try await phone.recordingCoverage(sessionID: plan.sessionID, configurationFingerprint: nil)
                report.receivedRanges = coverage.epochs.flatMap(\.received)
                try CaptureReplay.require(coverage.analyzedDuration == nil && coverage.transcribedDuration == nil && coverage.watchCapturedDuration == nil,
                    "Fixture storage replay must not claim ASR or real Watch capture coverage")
            }
            var next: Int64 = 0
            for range in try FrameRange.union(report.receivedRanges) {
                if range.start > next { report.missingRequestedRanges.append(try FrameRange(start: next, count: range.start - next)) }
                next = max(next, range.end)
            }
            if next < plan.plannedFrames { report.missingRequestedRanges.append(try FrameRange(start: next, count: plan.plannedFrames - next)) }
            report.uncoveredRequestedFrames = report.missingRequestedRanges.reduce(0) { $0 + $1.count }
            try sampleResources()
        } catch {
            report.status = "failed"
            report.failure = "\(report.failure.map { $0 + "; " } ?? "")Final evidence: \(error)"
        }
        report.finishedAt = Date(); report.totalElapsedSeconds = start.duration(to: .now).replaySeconds
        report.updateMissingCounts()
        try saveReport()
        print("\(report.status.uppercased()): mode=\(plan.mode) codec=\(options.codec.rawValue) plannedFrames=\(plan.plannedFrames) appendedFrames=\(report.appendedFrames) receivedFrames=\(report.receivedFrames) actualSeconds=\(report.totalElapsedSeconds)")
        print("Evidence: \(options.output.appendingPathComponent("report.json").path)")
        print("Generated fixture only. Watch, WatchConnectivity, ASR and model API were not executed.")
        if report.status == "failed" { return 1 }
        if let signal = stop.receivedSignal { return 128 + signal }
        return 0
    }

    private func persistAndDeliver(_ encoded: EncodedChunk) async throws {
        let began = ContinuousClock.now
        let m = encoded.envelope.manifest
        try CaptureReplay.require(m.sourceKind == .fixture && m.frames.start == report.sealedFrames && m.sequence == Int64(report.sealedChunks),
            "Chunk source, sequence, or frame boundary is discontinuous")
        try CaptureReplay.require(m.frames.count > 0 && m.frames.count <= ReplayOptions.segmentFrames && m.frames.end <= report.appendedFrames,
            "Chunk frame range exceeds the actual appended input")
        try ReplayEvidence.requireDisk(options.output, remainingFrames: plan.plannedFrames - report.confirmedFrames)
        let stored = try await watch.sealChunk(audioAt: encoded.audioURL, envelope: encoded.envelope)
        report.sealedFrames = m.frames.end; report.sealedChunks += 1; report.encodedBytes += m.byteCount
        sealed.append(encoded.envelope)
        try event("sealed", encoded.envelope)
        // These scratch files belong to this tool. The ledger has already preserved an independent copy.
        try FileManager.default.removeItem(at: encoded.audioURL)
        if options.codec == .aac {
            try FileManager.default.removeItem(at: encoded.audioURL.appendingPathExtension("draft.json"))
            try FileManager.default.removeItem(at: encoded.audioURL.appendingPathExtension("sealed.json"))
        }
        let transport = options.output.appendingPathComponent("transfer-\(m.chunkID).audio")
        try FileManager.default.copyItem(at: stored.audioURL, to: transport)
        let inbox = try phone.inbox.preserve(fileURL: transport, envelope: encoded.envelope)
        try CaptureReplay.require(!FileManager.default.fileExists(atPath: transport.path), "Inbox did not take ownership of the transfer copy")
        report.transferredBytes += m.byteCount
        guard case .accepted(let receipt) = try await phone.commitReceivedChunk(inbox) else {
            throw VerificationFailure(description: "Unique continuous replay chunk was not accepted")
        }
        try CaptureReplay.require(receipt.matches(encoded.envelope), "Receipt hashes differ from the sealed chunk")
        report.receivedFrames = m.frames.end; report.receivedChunks += 1
        try event("received", encoded.envelope)
        let applied = try await watch.applyReceipt(receipt)
        try await phone.applyReceipt(applied)
        let cleaned = try await watch.cleanupAcknowledgedChunks()
        try CaptureReplay.require(cleaned == [m.chunkID], "Watch cleanup differs from the just-confirmed chunk")
        report.confirmedFrames = m.frames.end
        try event("confirmed", encoded.envelope)
        report.persistenceAndDeliverySeconds += began.duration(to: .now).replaySeconds
        report.updateMissingCounts()
        try sampleResources(); try saveReport()
        print("sealed=\(report.sealedChunks) frames=\(report.appendedFrames)/\(plan.plannedFrames) actualSeconds=\(start.duration(to: .now).replaySeconds)")
    }

    private func verifyAfterReopen(stop: ReplayStopFlag) async throws {
        let reopenedWatch = try RecordingStore(rootURL: options.output.appendingPathComponent("watch"))
        let reopenedPhone = try ArchiveStore(rootURL: options.output.appendingPathComponent("phone"), receiverDeviceID: plan.receiverDeviceID)
        let recovery = try await reopenedWatch.recover()
        try CaptureReplay.require(recovery.missing.isEmpty && recovery.damaged.isEmpty && recovery.unfinished.isEmpty,
            "Watch restart found damaged, missing or unfinished sealed files")
        let pendingWatchCount = try await reopenedWatch.pendingChunkCount()
        let pendingInbox = try reopenedPhone.inbox.pendingItems()
        try CaptureReplay.require(pendingWatchCount == 0 && pendingInbox.isEmpty,
            "Final receive queues are not empty")
        var verifiedFrames: Int64 = 0
        var pcmHash = SHA256()
        for envelope in sealed {
            if stop.receivedSignal != nil { return }
            let m = envelope.manifest
            let lease = try await reopenedPhone.acquireAudioLease(chunkID: m.chunkID)
            do {
                try Self.verifyAudio(lease.audioURL, manifest: m, pcmHash: &pcmHash)
            } catch { await reopenedPhone.releaseAudioLease(id: lease.id); throw error }
            await reopenedPhone.releaseAudioLease(id: lease.id)
            try CaptureReplay.require(try await reopenedWatch.chunk(id: m.chunkID)?.state == .removed, "Confirmed Watch file was requeued after reopen")
            try CaptureReplay.require(m.frames.start == verifiedFrames, "Final audio coverage has a gap or overlap")
            verifiedFrames = m.frames.end; report.verifiedAfterReopenChunks += 1
            try event("verified-after-reopen", envelope)
        }
        try CaptureReplay.require(verifiedFrames == report.appendedFrames, "Reopened audio does not cover every appended frame")
        let coverage = try await reopenedPhone.recordingCoverage(sessionID: plan.sessionID, configurationFingerprint: nil)
        let expected = report.appendedFrames == 0 ? [] : [try FrameRange(start: 0, count: report.appendedFrames)]
        try CaptureReplay.require(coverage.epochs.count == 1 && coverage.epochs[0].received == expected &&
            coverage.epochs[0].closedAtFrame == report.appendedFrames && coverage.epochs[0].notReceived.isEmpty &&
            coverage.epochs[0].unavailableAudio.isEmpty, "Reopened archive coverage or epoch closure is incomplete")
        let watchApplications = try await reopenedWatch.pendingReceiptApplications()
        let phoneReceipts = try await reopenedPhone.pendingReceipts()
        try CaptureReplay.require(watchApplications.count == sealed.count && phoneReceipts.isEmpty,
            "Durable receipt state differs after reopening both stores")
        if options.codec == .pcm {
            report.reopenedPCMSHA256 = Self.digest(pcmHash)
            try CaptureReplay.require(report.reopenedPCMSHA256 == Self.digest(appendedHash), "PCM replay samples changed across file boundaries or storage")
        }
        report.finalVerificationComplete = true
    }

    private static func verifyAudio(_ url: URL, manifest: ChunkManifest, pcmHash: inout SHA256) throws {
        try CaptureReplay.require(try ContentHash.sha256(fileAt: url) == manifest.audioSHA256, "Reopened audio SHA-256 changed")
        let file = try AVAudioFile(forReading: url,
            commonFormat: manifest.codec == .pcmInt16 ? .pcmFormatInt16 : .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw VerificationFailure(description: "Cannot allocate bounded decode buffer")
        }
        var count: Int64 = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try CaptureReplay.require(buffer.frameLength > 0, "Decoder made no progress")
            if manifest.codec == .pcmInt16 {
                guard let samples = buffer.int16ChannelData?[0] else { throw VerificationFailure(description: "PCM decoder returned a different sample format") }
                pcmHash.update(data: Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size))
            }
            count += Int64(buffer.frameLength)
        }
        try CaptureReplay.require(count == manifest.decodedFrameCount && count - manifest.primingFrames - manifest.paddingFrames == manifest.frames.count,
            "Decoded frame count differs from source coverage")
    }

    private func makeSamples(count: Int) -> [Int16] {
        (0..<count).map { _ in
            generator ^= generator << 13; generator ^= generator >> 7; generator ^= generator << 17
            return Int16((Int32(generator >> 48) - 32_768) / 32)
        }
    }
    private func event(_ stage: String, _ envelope: ManifestEnvelope) throws {
        try ReplayEvidence.append(ReplayChunkEvent(stage: stage, envelope: envelope,
            elapsedSeconds: start.duration(to: .now).replaySeconds, speed: options.speed), to: options.output.appendingPathComponent("chunks.jsonl"))
    }
    private func sampleResources() throws {
        try ReplayEvidence.append(ReplayResourceSample.read(root: options.output,
            elapsedSeconds: start.duration(to: .now).replaySeconds, appendedFrames: report.appendedFrames),
            to: options.output.appendingPathComponent("resources.jsonl"))
    }
    private static func digest(_ hash: SHA256) -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
    private func saveReport() throws {
        report.generatedPCMSHA256 = Self.digest(generatedHash)
        report.appendedPCMSHA256 = Self.digest(appendedHash)
        try ReplayEvidence.save(report, to: options.output.appendingPathComponent("report.json"))
    }
}

private enum ReplayWriter {
    case aac(AACSegmentWriter)
    case pcm(PCM16SegmentWriter)

    init(options: ReplayOptions, plan: ReplayPlan, anchor: Date) throws {
        let directory = options.output.appendingPathComponent("encoding")
        switch options.codec {
        case .aac:
            self = .aac(try AACSegmentWriter(directory: directory, sessionID: plan.sessionID, epochID: plan.epochID,
                sourceDeviceID: plan.sourceDeviceID, sourceBuild: "capture-replay-paced-v1", sourceKind: .fixture,
                inputSampleRate: 16_000, wallClockAnchor: anchor, timezoneOffset: 0))
        case .pcm:
            self = .pcm(try PCM16SegmentWriter(directory: directory, sessionID: plan.sessionID, epochID: plan.epochID,
                sourceDeviceID: plan.sourceDeviceID, sourceBuild: "capture-replay-paced-v1", sourceKind: .fixture,
                wallClockAnchor: anchor, timezoneOffset: 0))
        }
    }
    mutating func append(_ input: [Int16]) throws -> [EncodedChunk] {
        switch self {
        case .aac(let writer): return try writer.append(input.map { Float($0) / 32_768 })
        case .pcm(var writer):
            let result = try writer.append(input)
            self = .pcm(writer)
            return result
        }
    }
    mutating func finish() throws -> [EncodedChunk] {
        switch self {
        case .aac(let writer): return try writer.finish()
        case .pcm(var writer):
            let result = try writer.finish()
            self = .pcm(writer)
            return result.map { [$0] } ?? []
        }
    }
}
