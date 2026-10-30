#if MOMO_ARCHIVE_STANDALONE
import Foundation
import MoMoContracts
import MoMoArchive

enum CheckFailure: Error { case failed(String) }
func check(_ value: Bool, _ message: String) throws { if !value { throw CheckFailure.failed(message) } }

@main struct StandaloneArchiveChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.failed("Pass an isolated test directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let receiver = UUID(), source = UUID(), session = UUID(), epoch = UUID(), chunk = UUID()
        let audio = makeWAVFixture()
        let frameRange = try FrameRange(start: 0, count: 1600)
        let manifest = try ChunkManifest(sessionID: session, epochID: epoch, chunkID: chunk, sourceDeviceID: source,
                                         sourceBuild: "standalone", sequence: 0, frames: frameRange, timebaseHz: 16000,
                                         wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 28800,
                                         codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
                                         byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture)
        let envelope = try ManifestEnvelope(manifest: manifest)
        let store = try ArchiveStore(rootURL: root, receiverDeviceID: receiver)
        func deliver(_ store: ArchiveStore, _ bytes: Data = audio) throws -> InboxItem {
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: temporary)
            return try store.inbox.preserve(fileURL: temporary, envelope: envelope)
        }
        let invalid = try deliver(store, Data(repeating: 1, count: audio.count))
        do { _ = try await store.commitReceivedChunk(invalid); throw CheckFailure.failed("Corrupt audio was accepted") }
        catch ArchiveError.checksumMismatch {}
        try FileManager.default.removeItem(at: invalid.directoryURL)
        try check(try await store.pendingReceipts().isEmpty, "Corrupt audio produced receipt")
        let item = try deliver(store)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(item) else { throw CheckFailure.failed("Initial receive") }
        let restarted = try ArchiveStore(rootURL: root, receiverDeviceID: receiver)
        try check(try await restarted.pendingReceipts() == [receipt], "Receipt did not persist")
        guard case .duplicate(let duplicate) = try await restarted.commitReceivedChunk(deliver(restarted)) else { throw CheckFailure.failed("Duplicate receive") }
        try check(duplicate == receipt, "Duplicate receipt identity drifted")
        let originalLease = try await restarted.acquireAudioLease(chunkID: chunk)
        await restarted.releaseAudioLease(id: originalLease.id)
        try FileManager.default.removeItem(at: originalLease.audioURL)
        try check(try await restarted.pendingReceipts().isEmpty, "Missing audio receipt remained pending")
        let replacement = try deliver(restarted)
        guard case .restored(let repaired) = try await restarted.commitReceivedChunk(replacement), repaired == receipt else { throw CheckFailure.failed("Retransmitted audio repair") }
        try check(try ContentHash.sha256(fileAt: originalLease.audioURL) == manifest.audioSHA256, "Repaired audio differs")
        guard let old = try await restarted.claimAnalysisJob(configurationHash: "local-model-v1") else { throw CheckFailure.failed("No analysis job") }
        try await restarted.recoverInterruptedJobs()
        guard let current = try await restarted.claimAnalysisJob(configurationHash: "local-model-v1") else { throw CheckFailure.failed("No recovered job") }
        let span = TranscriptSpan(chunkID: chunk, frames: frameRange, text: "下周安排在周一确认设计评审。")
        do { _ = try await restarted.commitTranscript(ticket: old, spans: [span]); throw CheckFailure.failed("Stale attempt committed") }
        catch ArchiveError.staleAttempt {}
        let transcript = try await restarted.commitTranscript(ticket: current, spans: [span])
        try check(try await restarted.searchTranscripts(query: "下周安排").count == 1, "Chinese search")
        try await restarted.projectPendingDocuments()
        let markdown = try await restarted.transcriptFileURL(sessionID: session)
        try check(try String(contentsOf: markdown, encoding: .utf8).contains(span.text), "Markdown projection")
        let reference = transcript.source(for: transcript.spans[0])
        let operationID = UUID()
        let firstPlan = try await restarted.savePlan(operationID: operationID, title: "安排", body: "周一确认评审时间。", sources: [reference])
        let repeatPlan = try await restarted.savePlan(operationID: operationID, title: "安排", body: "周一确认评审时间。", sources: [reference])
        try check(firstPlan.id == repeatPlan.id, "Plan duplicated")
        let agent = UUID()
        try await restarted.registerAgentSources(agentSessionID: agent, sources: [reference])
        let edited = try String(contentsOf: markdown, encoding: .utf8).replacingOccurrences(of: "周一", with: "周二")
        try Data(edited.utf8).write(to: markdown, options: .atomic)
        let reconciled = try await restarted.reconcileDocumentFiles()
        for entry in reconciled { _ = try entry.result.get() }
        try check(try await restarted.searchTranscripts(query: "周二").count == 1, "Markdown edit was not reconciled")
        try check(try await restarted.agentCanResume(agentSessionID: agent) == false, "Old Agent history was allowed")
        try check(try await restarted.plans().isEmpty, "Stale plan remained readable")
        try await restarted.markAgentCleanupCompleted(agentSessionID: agent)
        try check(try await restarted.agentCanResume(agentSessionID: agent), "Agent cleanup did not unblock")
        try await restarted.applyReceipt(ReceiptApplied(receipt: receipt))
        let lease = try await restarted.acquireAudioLease(chunkID: chunk)
        try check(try await restarted.expireAudio(olderThan: Date().addingTimeInterval(3600), replayFloors: [epoch: frameRange.end]).isEmpty, "Active audio reader expired")
        await restarted.releaseAudioLease(id: lease.id)
        try check(try await restarted.expireAudio(olderThan: Date().addingTimeInterval(3600), replayFloors: [epoch: frameRange.end]) == [chunk], "Eligible audio did not expire")
        guard case .expired = try await restarted.commitReceivedChunk(deliver(restarted)) else { throw CheckFailure.failed("Expired audio resurrected") }
        _ = try await restarted.deleteSession(id: session)
        let afterDelete = try ArchiveStore(rootURL: root, receiverDeviceID: receiver)
        guard case .deleted = try await afterDelete.commitReceivedChunk(deliver(afterDelete)) else { throw CheckFailure.failed("Deleted session resurrected") }
        try check(try await afterDelete.recordings().isEmpty, "Deleted recording visible")
        try check(try await afterDelete.searchTranscripts(query: "下周").isEmpty, "Deleted transcript searchable")
        try check(try await afterDelete.pendingReceipts().isEmpty, "Deleted session receipt pending")
        try await verifyCrossChunkArchive(root: root.appendingPathComponent("CrossChunk"), receiver: receiver, source: source)
        print("PASS: durable receive, corruption rejection, duplicate receipt, restart recovery, explicit missing-audio repair, stale attempt, Chinese search, JSON/Markdown projection, plan deduplication, Markdown revision, Agent cleanup gate, receipt-applied retention, audio lease, expiry, deletion barrier, cross-chunk windows, coverage/checkpoint recovery, playback timeline, append preserves references")
        print("Evidence directory: \(root.path)")
    }
}

private func verifyCrossChunkArchive(root: URL, receiver: UUID, source: UUID) async throws {
    let session = UUID(), epoch = UUID(), audio = makeWAVFixture()
    let store = try ArchiveStore(rootURL: root, receiverDeviceID: receiver)
    let fingerprint = ContentHash.sha256(Data("cross-chunk-model".utf8))
    func envelope(_ sequence: Int64) throws -> ManifestEnvelope {
        try ManifestEnvelope(manifest: ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: source,
            sourceBuild: "cross-chunk-check", sequence: sequence, frames: FrameRange(start: sequence * 1600, count: 1600),
            timebaseHz: 16000, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 28800,
            codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
            byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .fixture))
    }
    func deliver(_ envelope: ManifestEnvelope) async throws {
        let file = root.appendingPathComponent(UUID().uuidString)
        try audio.write(to: file)
        _ = try await store.commitReceivedChunk(store.inbox.preserve(fileURL: file, envelope: envelope))
    }
    let first = try envelope(0), second = try envelope(1), third = try envelope(2)
    try await deliver(second)
    try check(try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) == nil, "Gap was filled with invented input")
    try await deliver(first)
    guard let batch = try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) else { throw CheckFailure.failed("No epoch job") }
    try check(batch.inputs.map { $0.envelope.manifest.chunkID } == [first.manifest.chunkID, second.manifest.chunkID], "Inputs not frame-ordered")
    let window = try ArchiveAnalysisWindow(id: ContentHash.sha256(Data("window-one".utf8)), sessionID: session, epochID: epoch,
        analysisAnchor: 0, coreFrames: FrameRange(start: 1200, count: 800), contextFrames: FrameRange(start: 1000, count: 1200),
        modelCoreFrames: FrameRange(start: 1200, count: 800), modelContextFrames: FrameRange(start: 1000, count: 1200),
        sources: [ArchiveWindowSource(chunkID: first.manifest.chunkID, manifestSHA256: first.manifestSHA256, audioSHA256: first.manifest.audioSHA256, sourceFrames: FrameRange(start: 1000, count: 600)),
                  ArchiveWindowSource(chunkID: second.manifest.chunkID, manifestSHA256: second.manifestSHA256, audioSHA256: second.manifest.audioSHA256, sourceFrames: FrameRange(start: 1600, count: 600))], configurationFingerprint: fingerprint)
    try await store.commitAnalysisBatch(ticket: batch, windows: [window], analyzedCoverage: [FrameRange(start: 0, count: 3200)],
        noSpeechCoverage: [FrameRange(start: 0, count: 1200), FrameRange(start: 2000, count: 1200)],
        checkpoint: ArchiveCheckpoint(sessionID: session, epochID: epoch, sourceFrame: 3200, configurationFingerprint: fingerprint), waitingForMoreAudio: true)
    let restarted = try ArchiveStore(rootURL: root, receiverDeviceID: receiver)
    try check(try await restarted.analysisReplayFloors(configurationFingerprint: fingerprint)[epoch] == 3200, "Checkpoint lost")
    guard let recognition = try await restarted.claimTranscriptionWindow(configurationFingerprint: fingerprint) else { throw CheckFailure.failed("Window job lost") }
    try check(recognition.inputs.count == 2 && recognition.window.id == window.id, "Window inputs not restored")
    let document = try await restarted.commitWindowTranscript(ticket: recognition, text: "跨分片的设计评审讨论。", rawResult: Data("{\"text\":\"跨分片的设计评审讨论。\"}".utf8))
    try check(document.spans.count == 1 && document.spans[0].sourceRanges.count == 2, "Cross-chunk provenance lost")
    let reference = document.source(for: document.spans[0])
    let parts = try await restarted.acquireAudioTimeline(source: reference)
    try check(parts.count == 2 && parts[0].frames.end == parts[1].frames.start, "Playback timeline is incomplete")
    for part in parts { await restarted.releaseAudioLease(id: part.lease.id) }
    let agent = UUID()
    try await restarted.registerAgentSources(agentSessionID: agent, sources: [reference])
    _ = try await restarted.savePlan(operationID: UUID(), title: "评审", body: "确认时间", sources: [reference])
    try await deliver(third)
    try await restarted.markEpochClosed(epochID: epoch, endFrame: 4800)
    guard let next = try await restarted.claimEpochAnalysis(configurationFingerprint: fingerprint) else { throw CheckFailure.failed("New audio did not resume") }
    try check(next.checkpoint?.sourceFrame == 3200 && next.inputs.count == 1 && next.epochClosed, "Resume inputs or closure incorrect")
    let later = try ArchiveAnalysisWindow(id: ContentHash.sha256(Data("window-two".utf8)), sessionID: session, epochID: epoch,
        analysisAnchor: 3200, coreFrames: FrameRange(start: 3400, count: 600), contextFrames: FrameRange(start: 3200, count: 1000),
        modelCoreFrames: FrameRange(start: 200, count: 600), modelContextFrames: FrameRange(start: 0, count: 1000),
        sources: [ArchiveWindowSource(chunkID: third.manifest.chunkID, manifestSHA256: third.manifestSHA256, audioSHA256: third.manifest.audioSHA256, sourceFrames: FrameRange(start: 3200, count: 1000))], configurationFingerprint: fingerprint)
    try await restarted.commitAnalysisBatch(ticket: next, windows: [later], analyzedCoverage: [FrameRange(start: 3200, count: 1600)],
        noSpeechCoverage: [FrameRange(start: 3200, count: 200), FrameRange(start: 4000, count: 800)],
        checkpoint: ArchiveCheckpoint(sessionID: session, epochID: epoch, sourceFrame: 4800, configurationFingerprint: fingerprint), waitingForMoreAudio: false)
    guard let nextRecognition = try await restarted.claimTranscriptionWindow(configurationFingerprint: fingerprint) else { throw CheckFailure.failed("Second window lost") }
    _ = try await restarted.commitWindowTranscript(ticket: nextRecognition, text: "新增讨论。", rawResult: Data("{}".utf8))
    try await restarted.validateSources([reference])
    try check(try await restarted.agentCanResume(agentSessionID: agent), "Append invalidated unchanged context")
    try check(try await restarted.plans().count == 1, "Append invalidated existing plan")
}

private func makeWAVFixture() -> Data {
    var data = Data("RIFF".utf8)
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    u32(3236); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(16000); u32(32000); u16(2); u16(16)
    data.append(Data("data".utf8)); u32(3200); data.append(Data(repeating: 0, count: 3200))
    return data
}

#endif
