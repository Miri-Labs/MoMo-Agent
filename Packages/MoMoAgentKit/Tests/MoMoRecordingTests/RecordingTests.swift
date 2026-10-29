import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct RecordingFixture {
    let root: URL
    let source: URL
    let envelope: ManifestEnvelope
    let receiverID = UUID()
    let libraryID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoRecordingTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("input.pcm")
        let data = Data((0..<320).map { UInt8($0 % 255) })
        try data.write(to: source)
        envelope = try ManifestEnvelope(manifest: ChunkManifest(
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "tests",
            sequence: 0, frames: FrameRange(start: 0, count: 160), timebaseHz: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 100), timezoneOffset: 28_800,
            codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 160,
            byteCount: Int64(data.count), audioSHA256: ContentHash.sha256(data), sourceKind: .fixture
        ))
    }

    func store(_ name: String = "watch") throws -> RecordingStore { try RecordingStore(rootURL: root.appendingPathComponent(name)) }
    func receipt(audioHash: String? = nil, library: UUID? = nil) throws -> Receipt {
        try Receipt(receiverDeviceID: receiverID, libraryInstanceID: library ?? libraryID,
                    chunkID: envelope.manifest.chunkID, audioSHA256: audioHash ?? envelope.manifest.audioSHA256,
                    manifestSHA256: envelope.manifestSHA256)
    }
    func clean() { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
}

@Test func changingReceiverRequiresConfirmationAndInvalidatesOldCleanupAuthority() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
    _ = try await store.applyReceipt(fixture.receipt())
    let nextLibrary = UUID()
    await #expect(throws: RecordingError.receiverMismatch) {
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: nextLibrary)
    }
    try await store.replaceReceiverAfterUserConfirmation(deviceID: fixture.receiverID, libraryInstanceID: nextLibrary)
    #expect(try await store.cleanupAcknowledgedChunks().isEmpty)
    #expect(try await store.pendingChunks().count == 1)
    #expect(try await store.pendingReceiptApplications().isEmpty)
    #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    await #expect(throws: RecordingError.receiverMismatch) { try await store.applyReceipt(fixture.receipt()) }
}

@Test func interruptedEpochAndMarkSurviveRestartWithoutInventingTailFrames() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let manifest = fixture.envelope.manifest
    try await store.saveIntent(.recording, sessionID: manifest.sessionID)
    try await store.beginEpoch(sessionID: manifest.sessionID, epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID)
    _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let mark = try CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID, sourceFrame: 80)
    try await store.recordMark(mark)
    let reopened = try fixture.store()
    let recovered = try await reopened.recoverInterruptedEpochs()
    #expect(recovered.count == 1 && recovered.first?.sealedThroughFrame == 160
        && recovered.first?.lastObservedFrame == 160 && recovered.first?.reason == .interrupted)
    #expect(try await reopened.recoverInterruptedEpochs().isEmpty)
    #expect(try await reopened.pendingCaptureEvents().contains(.captureMark(mark)))
    #expect(try await reopened.latestActiveSession() == nil)
    #expect(try await reopened.intent(sessionID: manifest.sessionID) == .stopped)
}

@available(macOS 15, iOS 18, watchOS 11, *)
@Test func speechAACUsesLessStorageWithoutDroppingFrames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoAACStorage-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try AACSegmentWriter(directory: root, sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
        sourceBuild: "tests", sourceKind: .fixture, inputSampleRate: 16_000,
        targetSeconds: 60, wallClockAnchor: Date(), timezoneOffset: 0)
    var chunks: [EncodedChunk] = []
    for start in stride(from: 0, to: 960_000, by: 1_000) {
        chunks += try writer.append((start..<(start + 1_000)).map {
            Float(0.2 * sin(Double($0) * 2 * .pi * 180 / 16_000)
                + 0.1 * sin(Double($0) * 2 * .pi * 730 / 16_000))
        })
    }
    chunks += try writer.finish()
    #expect(writer.totalFrames == 960_000)
    #expect(chunks.reduce(Int64(0)) { $0 + $1.envelope.manifest.decodedFrameCount } == 960_000)
    #expect(chunks.allSatisfy { $0.envelope.manifest.codec == .aac && $0.envelope.manifest.channels == 1 })
    #expect(chunks.reduce(Int64(0)) { $0 + $1.envelope.manifest.byteCount } < 216_000)
}

@available(macOS 15, iOS 18, watchOS 11, *)
@Test func continuousAACResamplingPreservesFullChunksAndShortTail() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoAAC-\(UUID())")
    defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
    let writer = try AACSegmentWriter(directory: root, sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "tests", sourceKind: .fixture, inputSampleRate: 48_000, targetSeconds: 1, wallClockAnchor: Date(), timezoneOffset: 0)
    var chunks: [EncodedChunk] = []
    for offset in stride(from: 0, to: 120_000, by: 1_024) {
        chunks += try writer.append((offset..<min(offset + 1_024, 120_000)).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.3) })
    }
    chunks += try writer.finish()
    #expect(writer.totalFrames == 40_000)
    #expect(chunks.map { $0.envelope.manifest.frames.count } == [16_000, 16_000, 8_000])
    #expect(chunks.map { $0.envelope.manifest.frames.start } == [0, 16_000, 32_000])
    for chunk in chunks {
        let m = chunk.envelope.manifest
        #expect(m.codec == .aac && m.decodedFrameCount == m.frames.count && m.primingFrames == 0)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == m.audioSHA256)
    }
}

@available(macOS 15, iOS 18, watchOS 11, *)
@Test func boundedHandoffFailureSealsAcceptedTailBeforeReportingFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoCapture-\(UUID())")
    defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
    let store = try RecordingStore(rootURL: root.appendingPathComponent("ledger"))
    let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
    for index in 0..<16 {
        pair.continuation.yield(CapturedAudioBlock(mono: Array(repeating: 0.1, count: 1_024),
                                                 sampleTime: Int64(index * 1_024), uptime: Double(index) / 16,
                                                 wallClock: Date(), normalizedLevel: 0.1))
    }
    pair.continuation.finish(throwing: AudioCaptureError.bufferOverflow)
    await #expect(throws: AudioCaptureError.bufferOverflow) {
        try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
                                     directory: root.appendingPathComponent("encoder"), sessionID: UUID(),
                                     epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "tests",
                                     sourceKind: .fixture, store: store, progress: { _ in })
    }
    let chunks = try await store.pendingChunks()
    #expect(chunks.count == 1 && chunks.first?.envelope.manifest.frames.count == 16_384)
}

@available(macOS 15, iOS 18, watchOS 11, *)
@Test func closedAACRecoversWhenProcessStopsBeforeLedgerCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSpool-\(UUID())")
    defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
    let session = UUID(), epoch = UUID(), device = UUID()
    let spool = root.appendingPathComponent("spool")
    let writer = try AACSegmentWriter(directory: spool.appendingPathComponent(session.uuidString).appendingPathComponent(epoch.uuidString),
                                      sessionID: session, epochID: epoch, sourceDeviceID: device, sourceBuild: "tests",
                                      sourceKind: .fixture, inputSampleRate: 16_000, wallClockAnchor: Date(), timezoneOffset: 0)
    _ = try writer.append(Array(repeating: 0.1, count: 1_024))
    let original = try #require(writer.finish().first)
    let damagedAudio = original.audioURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
    try Data([0, 1, 2]).write(to: damagedAudio)
    let damagedMetadata = SealedCaptureSpool.sidecar(for: damagedAudio)
    try Data("{incomplete".utf8).write(to: damagedMetadata)
    let store = try RecordingStore(rootURL: root.appendingPathComponent("ledger"))
    let recovered = try await CaptureSpool.recover(directory: spool, store: store)
    #expect(recovered.recovered == [original.envelope.manifest.chunkID])
    #expect(recovered.damagedFiles == [damagedMetadata.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: damagedAudio.path))
    #expect(FileManager.default.fileExists(atPath: damagedMetadata.path))
    #expect(try await store.pendingChunks().first?.envelope.manifestSHA256 == original.envelope.manifestSHA256)
    #expect(!FileManager.default.fileExists(atPath: original.audioURL.path))
    #expect(try await CaptureSpool.recover(directory: spool, store: store).recovered.isEmpty)
}

@Test func sealedChunkIsRecoveredFromReadyWithoutAnIndex() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let recovered = try fixture.store("recovered")
    let recoveredReady = fixture.root.appendingPathComponent("recovered/CaptureReady").appendingPathComponent(fixture.envelope.manifest.chunkID.uuidString)
    try FileManager.default.copyItem(at: chunk.audioURL.deletingLastPathComponent(), to: recoveredReady)
    let report = try await recovered.recover()
    #expect(report.registered == [fixture.envelope.manifest.chunkID])
    let pending = try await recovered.pendingChunks()
    #expect(pending.count == 1)
    #expect(try Data(contentsOf: pending[0].audioURL) == Data(contentsOf: fixture.source))
    #expect(pending[0].envelope.manifestData == fixture.envelope.manifestData)
}

@Test(arguments: [false, true])
func sealingRetriesAnInterruptedCopyFromTheVerifiedClosedSource(hasPartialAudio: Bool) async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let working = fixture.root.appendingPathComponent("watch/CaptureWorking").appendingPathComponent(fixture.envelope.manifest.chunkID.uuidString)
    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
    try WireJSON.encode(fixture.envelope).write(to: working.appendingPathComponent("draft.json"))
    if hasPartialAudio { try Data([1, 2, 3]).write(to: working.appendingPathComponent("audio")) }
    #expect(try await store.recover().unfinished == [working.lastPathComponent])
    let recovered = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    #expect(try ContentHash.sha256(fileAt: recovered.audioURL) == fixture.envelope.manifest.audioSHA256)
    #expect(try await store.pendingChunks().count == 1)
    #expect(!FileManager.default.fileExists(atPath: working.path))
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
}

@Test func emptyWorkingDirectoryCannotBlockUnrelatedDeletion() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let empty = fixture.root.appendingPathComponent("watch/CaptureWorking").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    let deletion = try DeleteSession(sessionID: fixture.envelope.manifest.sessionID, generation: 1)
    try await store.prepareDeletion(deletion, deviceID: fixture.envelope.manifest.sourceDeviceID)
    _ = try await store.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
    #expect(!FileManager.default.fileExists(atPath: empty.path))
    #expect(try await store.pendingDeletions().isEmpty)
    #expect(try await store.pendingDeletionApplications().count == 1)
}

@Test func receiptCannotDeleteBeforeDurableVerificationAndSurvivesReopen() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    #expect(try await store.cleanupAcknowledgedChunks().isEmpty)
    #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    await #expect(throws: RecordingError.receiverNotBound) { try await store.applyReceipt(fixture.receipt()) }
    try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
    await #expect(throws: RecordingError.receiverMismatch) { try await store.applyReceipt(fixture.receipt(library: UUID())) }
    await #expect(throws: RecordingError.receiptMismatch) { try await store.applyReceipt(fixture.receipt(audioHash: String(repeating: "0", count: 64))) }
    #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    let receipt = try fixture.receipt()
    let applied = try await store.applyReceipt(receipt)
    #expect(try await store.applyReceipt(receipt) == applied)
    #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    let reopened = try fixture.store()
    #expect(try await reopened.pendingReceiptApplications() == [applied])
    #expect(try await reopened.recover().cleaned == [fixture.envelope.manifest.chunkID])
    #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
    #expect(try await reopened.pendingReceiptApplications() == [applied])
    #expect(try await reopened.chunk(id: fixture.envelope.manifest.chunkID)?.state == .removed)
}

@Test func deletionBlocksLateSealingAndRequiresCompletedCleanupBeforeAcknowledgment() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let deletion = try DeleteSession(sessionID: fixture.envelope.manifest.sessionID, generation: 1)
    try await store.prepareDeletion(deletion, deviceID: fixture.envelope.manifest.sourceDeviceID)
    #expect(try await store.pendingDeletionApplications().isEmpty)
    #expect(try await store.pendingDeletions() == [deletion])
    await #expect(throws: RecordingError.deletedSession(deletion.sessionID)) {
        try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    }
    let reopened = try fixture.store()
    let applied = try await reopened.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
    #expect(!FileManager.default.fileExists(atPath: chunk.audioURL.path))
    #expect(try await reopened.pendingDeletionApplications() == [applied])
    try await reopened.prepareDeletion(deletion, deviceID: fixture.envelope.manifest.sourceDeviceID)
    #expect(try await reopened.pendingDeletionApplications() == [applied])
}

@Test func damagedTailDoesNotInvalidateEarlierSealedChunk() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let tail = fixture.root.appendingPathComponent("watch/CaptureWorking").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tail, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: tail.appendingPathComponent("audio"))
    let report = try await store.recover()
    #expect(report.unfinished == [tail.lastPathComponent])
    #expect(try await store.pendingChunks().count == 1)
}

@Test func finalizedWorkingDirectoryPromotesAfterInterruptionBeforeRename() async throws {
    let fixture = try RecordingFixture()
    defer { fixture.clean() }
    let store = try fixture.store()
    let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
    let recoveredRoot = fixture.root.appendingPathComponent("promoted")
    let recovered = try RecordingStore(rootURL: recoveredRoot)
    let working = recoveredRoot.appendingPathComponent("CaptureWorking").appendingPathComponent(fixture.envelope.manifest.chunkID.uuidString)
    try FileManager.default.copyItem(at: chunk.audioURL.deletingLastPathComponent(), to: working)
    #expect(try await recovered.recover().registered == [fixture.envelope.manifest.chunkID])
    #expect(!FileManager.default.fileExists(atPath: working.path))
    #expect(try await recovered.pendingChunks().count == 1)
}

@Test func pcmBoundariesPreserveRepeatedSamplesAndShortTail() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPCMTests-\(UUID())")
    defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
    let input: [Int16] = [1, 1, -2, -2, 3, 3, -4, -4, 5, 5, -6, -6, 7]
    var writer = try PCM16SegmentWriter(directory: root, sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "test", sourceKind: .fixture, targetFrames: 5, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0)
    var chunks = try writer.append(Array(input.prefix(7)))
    chunks += try writer.append(Array(input.dropFirst(7)))
    let tail = try writer.finish()
    chunks.append(try #require(tail))
    #expect(chunks.map { $0.envelope.manifest.frames.start } == [0, 5, 10])
    #expect(chunks.map { $0.envelope.manifest.frames.count } == [5, 5, 3])
    var decoded: [Int16] = []
    for chunk in chunks {
        let payload = Array(try Data(contentsOf: chunk.audioURL).dropFirst(44))
        decoded += stride(from: 0, to: payload.count, by: 2).map { Int16(bitPattern: UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8) }
    }
    #expect(decoded == input)
    #expect(throws: SegmentWriterError.alreadyFinished) { try writer.append([8]) }
}

@Test func pauseAndOldCallbackCannotResumeCapture() throws {
    var state = CaptureState()
    let generation = state.start()
    #expect(state.activity == .starting)
    let received = state.receivedSamples(frames: 10, uptime: 10, generation: generation)
    #expect(received)
    state.interrupt()
    state.pause()
    #expect(state.resumeAfterInterruption(systemAllows: true) == nil)
    let receivedAfterPause = state.receivedSamples(frames: 10, uptime: 11, generation: generation)
    #expect(!receivedAfterPause)
    state.restore(intent: .recording)
    #expect(state.activity == .interrupted)
    var buffer = try PCMBuffer(maximumFrames: 4)
    try buffer.append([1, 2, 3])
    #expect(throws: PCMBufferError.overflow(rejectedFrames: 2)) { try buffer.append([4, 5]) }
    #expect(buffer.drain() == [1, 2, 3])
}
