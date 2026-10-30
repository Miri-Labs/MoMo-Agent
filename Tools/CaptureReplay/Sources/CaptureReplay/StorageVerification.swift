import Foundation
import Darwin
import MoMoArchive
import MoMoContracts
import MoMoRecording

struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

struct StorageReport: Codable {
    let runID: UUID
    let sourceKind: String
    let evidenceLayer: String
    let startedAt: Date
    let finishedAt: Date
    let checks: [String]
    let notExecuted: [String]
}

@main
enum CaptureReplay {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "replay" {
            let result = try await ContinuousReplay.run(options: ReplayOptions(arguments: Array(arguments.dropFirst())))
            if result != 0 { exit(result) }
            return
        }
        guard arguments.count == 3, arguments[0] == "verify-storage", arguments[1] == "--output" else {
            throw VerificationFailure(description: ReplayOptions.usage)
        }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw VerificationFailure(description: "Output must be a new directory; existing files will not be removed.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let report = try await verify(root: root)
        try WireJSON.encode(report).write(to: root.appendingPathComponent("storage-report.json"), options: .atomic)
        print("PASS: \(report.checks.count) storage checks. Evidence: \(root.appendingPathComponent("storage-report.json").path)")
        print("Fixture-based file/SQLite verification only. Watch, WCSession, ASR, Pi and UI were not executed.")
    }

    static func verify(root: URL) async throws -> StorageReport {
        let began = Date()
        let runID = UUID()
        let watchID = UUID()
        let phoneID = UUID()
        let sessionID = UUID()
        var checks: [String] = []
        let watchRoot = root.appendingPathComponent("watch", isDirectory: true)
        let phoneRoot = root.appendingPathComponent("phone", isDirectory: true)
        let watch = try RecordingStore(rootURL: watchRoot)
        let phone = try ArchiveStore(rootURL: phoneRoot, receiverDeviceID: phoneID)
        try await watch.bindReceiver(deviceID: phoneID, libraryInstanceID: phone.libraryInstanceID)
        var writer = try PCM16SegmentWriter(
            directory: root.appendingPathComponent("input"), sessionID: sessionID,
            epochID: UUID(), sourceDeviceID: watchID, sourceBuild: "capture-replay-v1",
            sourceKind: .fixture, targetFrames: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 1_791_900_000), timezoneOffset: 28_800
        )
        let sampleCount = 37_501
        var encoded: [EncodedChunk] = []
        for offset in stride(from: 0, to: sampleCount, by: 512) {
            let count = min(512, sampleCount - offset)
            let samples = (0..<count).map { index in
                Int16(sin(Double(offset + index) * 2 * .pi * 440 / 16_000) * 8_000)
            }
            encoded += try writer.append(samples)
        }
        if let tail = try writer.finish() { encoded.append(tail) }
        try require(encoded.count == 3, "Expected two full PCM chunks and one short tail")
        try require(encoded.map { $0.envelope.manifest.frames.count }.reduce(0, +) == sampleCount, "PCM frames were lost")
        checks.append("PCM chunk boundaries and short tail conserve all input frames")

        for chunk in encoded {
            _ = try await watch.sealChunk(audioAt: chunk.audioURL, envelope: chunk.envelope)
        }
        try require(try await watch.pendingChunks().count == 3, "Watch must retain unacknowledged chunks")
        checks.append("Unacknowledged chunks persist in the Watch SQLite ledger")

        let epochID = encoded[0].envelope.manifest.epochID
        let mark = try CaptureMark(sessionID: sessionID, epochID: epochID, sourceDeviceID: watchID, sourceFrame: 8_000)
        try await phone.receiveMark(mark)
        try await phone.receiveMark(mark)
        try await phone.receiveEpochEnd(CaptureEpochEnded(sessionID: sessionID, epochID: epochID,
                                                         sourceDeviceID: watchID, endFrame: Int64(sampleCount), reason: .stopped))
        try require(try await phone.marks(sessionID: sessionID).count == 1, "Repeated mark created a duplicate")
        checks.append("Capture marks and epoch closure persist before their out-of-order audio arrives")

        // Simulate OS ownership by moving a distinct temporary copy through the synchronous inbox entry.
        for chunk in encoded.reversed() {
            let item = try transfer(chunk, phone: phone, root: root)
            let result = try await phone.commitReceivedChunk(item)
            guard case .accepted(let receipt) = result else {
                throw VerificationFailure(description: "First receive was not accepted")
            }
            try require(receipt.matches(chunk.envelope), "Receipt refers to different content")
            let application = try await watch.applyReceipt(receipt)
            try await phone.applyReceipt(application)
        }
        checks.append("Out-of-order files are validated, persisted and acknowledged with matching hashes")

        let duplicateItem = try transfer(encoded[0], phone: phone, root: root)
        guard case .duplicate = try await phone.commitReceivedChunk(duplicateItem) else {
            throw VerificationFailure(description: "Repeated receive did not return a duplicate receipt")
        }
        let recordings = try await phone.recordings()
        try require(recordings.count == 1 && recordings[0].chunkCount == 3, "Duplicate receive changed logical archive count")
        checks.append("Repeated receive does not create duplicate recordings or chunks")

        let cleaned = try await watch.cleanupAcknowledgedChunks()
        try require(cleaned.count == 3, "Acknowledged Watch copies were not cleaned")
        let reopenedWatch = try RecordingStore(rootURL: watchRoot)
        try require(try await reopenedWatch.pendingReceiptApplications().count == 3, "ReceiptApplied was lost during cleanup")
        try require(try await reopenedWatch.pendingChunks().isEmpty, "Restart requeued acknowledged files")
        checks.append("Restart retains receipt applications after removing acknowledged audio")

        var completed = 0
        while let ticket = try await phone.claimAnalysisJob(configurationHash: ContentHash.sha256(Data("fixture-transcript-v1".utf8))) {
            let span = TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames,
                                      text: "固定输入档案验证片段 \(ticket.manifest.sequence)")
            _ = try await phone.commitTranscript(ticket: ticket, spans: [span])
            completed += 1
        }
        try require(completed == 3, "Duplicate or missing analysis jobs")
        try await phone.projectPendingDocuments()
        let transcript = try await phone.readTranscript(sessionID: sessionID)
        try require(transcript.spans.count == 3, "Transcript commits lost spans")
        let hits = try await phone.searchTranscripts(query: "档案验证")
        try require(hits.count == 3, "Chinese keyword search failed")
        checks.append("Fixture transcript commits project to files and support Chinese keyword search")

        let sources = transcript.spans.map { transcript.source(for: $0) }
        let operationID = UUID()
        let saved = try await phone.savePlan(operationID: operationID, title: "档案验收", body: "核对三个固定输入片段。", sources: sources)
        let repeated = try await phone.savePlan(operationID: operationID, title: "档案验收", body: "核对三个固定输入片段。", sources: sources)
        try require(saved.id == repeated.id, "Retry created another plan")
        try require(try await phone.plans().count == 1, "Visible plan was duplicated")
        checks.append("A repeated logical plan write has one visible effect")

        let agentSession = UUID()
        try await phone.registerAgentSources(agentSessionID: agentSession, sources: sources)
        let deletion = try await phone.deleteSession(id: sessionID)
        try require(try await !phone.agentCanResume(agentSessionID: agentSession), "Agent resumed before its deleted sources were cleaned")
        let lateItem = try transfer(encoded[0], phone: phone, root: root)
        guard case .deleted = try await phone.commitReceivedChunk(lateItem) else {
            throw VerificationFailure(description: "Late transfer revived a deleted recording")
        }
        try require(try await phone.recordings().isEmpty, "Deleted session remained visible")
        checks.append("Persistent deletion rejects late audio and blocks affected Agent resume")

        _ = try await reopenedWatch.prepareDeletion(deletion, deviceID: watchID)
        _ = try await reopenedWatch.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
        try require(try await reopenedWatch.pendingDeletionApplications().count == 1, "Completed peer deletion did not persist")
        checks.append("Peer deletion is acknowledged only after explicit capture-stop cleanup")

        let reopenedPhone = try ArchiveStore(rootURL: phoneRoot, receiverDeviceID: phoneID)
        try require(try await reopenedPhone.recordings().isEmpty, "Restart revived deleted data")
        try require(reopenedPhone.libraryInstanceID == phone.libraryInstanceID, "Ordinary restart changed library identity")
        checks.append("Phone restart preserves deletion tombstones and library identity")

        return StorageReport(runID: runID, sourceKind: "fixture", evidenceLayer: "software-integration",
                             startedAt: began, finishedAt: Date(), checks: checks,
                             notExecuted: ["Watch microphone", "WatchConnectivity", "ASR/VAD", "Pi and real model API", "UI", "18-hour capture"])
    }

    static func transfer(_ chunk: EncodedChunk, phone: ArchiveStore, root: URL) throws -> InboxItem {
        let temporary = root.appendingPathComponent("transfer-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: chunk.audioURL, to: temporary)
        let item = try phone.inbox.preserve(fileURL: temporary, envelope: chunk.envelope)
        try require(!FileManager.default.fileExists(atPath: temporary.path), "Inbox did not take ownership synchronously")
        return item
    }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationFailure(description: message) }
    }
}
