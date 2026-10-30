import Darwin
import Foundation
import MoMoArchive
import MoMoContracts
import MoMoRecording

private struct CaptureFixture: Codable {
    let envelope: ManifestEnvelope
    let activeAudioRelativePath: String
    let submittedFrames: Int64
    let mark: CaptureMark
}

private struct SenderReport: Encodable {
    let phase: String
    let processID: Int32 = getpid()
    var recovered: [UUID] = []
    var incomplete: [String] = []
    var interruption: [CaptureEpochInterrupted] = []
    var controls: [ControlMessage] = []
    var receipt: Receipt?
    var applied: ReceiptApplied?
    var cleaned: [UUID] = []
    var expired: [UUID] = []
    var retentionBlockedBeforeApplication: Bool?
}

enum SenderCrashReplay {
    private static func stop(at boundary: String) throws -> Never {
        struct Event: Encodable { let event = "boundary"; let boundary: String; let processID: Int32 = getpid() }
        try emit(Event(boundary: boundary))
        guard raise(SIGSTOP) == 0 else { exit(71) }
        exit(72)
    }

    static func capture(phase: String, root: URL) async throws {
        if phase == "prepare" { try emit(SenderReport(phase: phase)); return }
        let store = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
        let spool = root.appendingPathComponent("Encoding")
        let fixtureURL = root.appendingPathComponent("capture-fixture.json")
        if phase == "receive" {
            let session = UUID(), epoch = UUID(), source = UUID()
            try await store.saveIntent(.recording, sessionID: session)
            try await store.beginEpoch(sessionID: session, epochID: epoch, sourceDeviceID: source)
            let directory = spool.appendingPathComponent(session.uuidString).appendingPathComponent(epoch.uuidString)
            let writer = try AACSegmentWriter(directory: directory, sessionID: session, epochID: epoch,
                sourceDeviceID: source, sourceBuild: "crash-recovery-replay-v2", sourceKind: .fixture,
                inputSampleRate: 16_000, targetSeconds: 1,
                wallClockAnchor: Date(timeIntervalSince1970: 1_792_022_400), timezoneOffset: 28_800)
            var sealed: [EncodedChunk] = []
            for batch in 0..<4 {
                sealed += try writer.append((0..<4_000).map { sin(Float(batch * 4_000 + $0) * 0.08) * 0.2 })
            }
            try require(sealed.count == 1 && writer.totalFrames == 16_000, "AAC fixture did not seal its first second")
            _ = try await store.sealChunk(audioAt: sealed[0].audioURL, envelope: sealed[0].envelope)
            let input = root.appendingPathComponent("input")
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sealed[0].audioURL, to: input.appendingPathComponent("sealed.m4a"))
            try require(try writer.append(Array(repeating: 0.15, count: 4_000)).isEmpty, "Active tail unexpectedly sealed")
            let mark = try CaptureMark(sessionID: session, epochID: epoch, sourceDeviceID: source, sourceFrame: writer.totalFrames)
            try await store.recordMark(mark)
            let drafts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".m4a.draft.json") && !$0.lastPathComponent.hasPrefix(sealed[0].envelope.manifest.chunkID.uuidString) }
            try require(drafts.count == 1, "Expected one real active AAC draft")
            let active = drafts[0].deletingPathExtension().deletingPathExtension()
            let fixture = CaptureFixture(envelope: sealed[0].envelope,
                activeAudioRelativePath: "Encoding/\(session)/\(epoch)/\(active.lastPathComponent)",
                submittedFrames: writer.totalFrames, mark: mark)
            try WireJSON.encode(fixture).write(to: fixtureURL, options: .withoutOverwriting)
            // No finish/deinit may finalize this live container before the parent's SIGKILL.
            try withExtendedLifetime(writer) { try stop(at: "J08-a") }
        }
        try require(["recover", "verify"].contains(phase), "Unknown capture recovery phase")
        let fixture = try WireJSON.decode(CaptureFixture.self, from: Data(contentsOf: fixtureURL))
        let manifest = fixture.envelope.manifest
        let ledger = try await store.recover()
        try require(ledger.missing.isEmpty && ledger.damaged.isEmpty, "Sealed AAC was damaged during restart")
        let recovery = try await CaptureSpool.recover(directory: spool, store: store)
        try require(recovery.damagedFiles.isEmpty, "AAC spool contained unexpected damaged metadata")
        var report = SenderReport(phase: phase)
        report.recovered = recovery.recovered; report.incomplete = recovery.incompleteFiles
        report.interruption = try await store.recoverInterruptedEpochs()
        try require(try await store.intent(sessionID: manifest.sessionID) == .stopped,
                    "The killed process's recording intent remained active")
        try require(try await store.latestActiveSession() == nil,
                    "Relaunch would reuse an old recording session")
        report.controls = try await store.pendingCaptureEvents()
        try require(report.controls.count == 2, "Mark or interruption event was lost or duplicated")
        try require(try await store.cleanupAcknowledgedChunks().isEmpty, "Unacknowledged AAC was deleted")
        let old = try await store.chunk(id: manifest.chunkID)
        try require(old?.envelope == fixture.envelope && old?.state == .ready, "Sealed AAC identity changed")
        let end = try await store.sealedEndFrame(sessionID: manifest.sessionID, epochID: manifest.epochID)
        try require(end >= 16_000 && end <= fixture.submittedFrames, "Recovery claimed unproven tail frames")
        if phase == "verify" { try require(report.interruption.isEmpty && recovery.recovered.isEmpty, "Repeated recovery created state") }
        try emit(report)
    }

    static func receipt(phase: String, root: URL, boundary: String) async throws {
        let fixture = try WireJSON.decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
        let phone = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverDeviceID)
        try require(phone.libraryInstanceID == fixture.libraryInstanceID, "Receiver identity changed")
        let watch = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
        let manifest = fixture.envelope.manifest
        let cutoff = manifest.sealedAt.addingTimeInterval(1)
        let floors = [manifest.epochID: manifest.frames.end]
        var report = SenderReport(phase: phase)
        if phase == "receive" {
            let delivery = root.appendingPathComponent("delivery.wav")
            try FileManager.default.copyItem(at: root.appendingPathComponent(fixture.watchAudioRelativePath), to: delivery)
            let item = try phone.inbox.preserve(fileURL: delivery, envelope: fixture.envelope)
            guard case .accepted(let receipt) = try await phone.commitReceivedChunk(item) else {
                throw ReplayFailure(description: "Expected a first durable receive")
            }
            guard let ticket = try await phone.claimAnalysisJob(configurationHash: "synthetic-complete-for-retention-isolation") else {
                throw ReplayFailure(description: "Expected the production analysis ticket")
            }
            // Synthetic empty transcript isolates ReceiptApplied's retention gate; this does not claim ASR validation.
            _ = try await phone.commitTranscript(ticket: ticket, spans: [])
            try require(try await phone.expireAudio(olderThan: cutoff, replayFloors: floors).isEmpty, "Phone expired before sender receipt")
            let applied = try await watch.applyReceipt(receipt)
            if boundary == "J08-f" {
                try require(try await watch.cleanupAcknowledgedChunks() == [manifest.chunkID], "Expected sender cleanup before interruption")
            }
            struct Persisted: Encodable { let receipt: Receipt; let applied: ReceiptApplied }
            try WireJSON.encode(Persisted(receipt: receipt, applied: applied))
                .write(to: root.appendingPathComponent("persisted-confirmation.json"), options: .withoutOverwriting)
            try stop(at: boundary)
        }
        try require(["recover", "verify"].contains(phase), "Unknown sender confirmation phase")
        let recovery = try await watch.recover()
        try require(recovery.missing.isEmpty && recovery.damaged.isEmpty, "Sender recovery damaged the ledger")
        report.cleaned = recovery.cleaned
        let applications = try await watch.pendingReceiptApplications()
        try require(applications.count == 1 && applications[0].receipt.matches(fixture.envelope), "ReceiptApplied did not survive cleanup/restart")
        let applied = applications[0]
        try require(try await watch.applyReceipt(applied.receipt) == applied, "Repeated receipt changed its message identity")
        try require(try await watch.cleanupAcknowledgedChunks().isEmpty, "Cleanup was not idempotent")
        try require(try await watch.pendingChunks().isEmpty, "Acknowledged source was requeued for upload")
        if phase == "recover" {
            try require(try await phone.pendingReceipts() == [applied.receipt], "Undelivered receipt disappeared from phone outbox")
            try require(try await phone.expireAudio(olderThan: cutoff, replayFloors: floors).isEmpty, "Phone expired without ReceiptApplied")
            report.retentionBlockedBeforeApplication = true
            try await phone.applyReceipt(applied)
            try await phone.applyReceipt(applied)
            try require(try await phone.pendingReceipts().isEmpty, "ReceiptApplied did not close the phone outbox")
        } else {
            try require(try await phone.pendingReceipts().isEmpty, "Receipt state changed on second restart")
            report.expired = try await phone.expireAudio(olderThan: cutoff, replayFloors: floors)
            try require(report.expired == [manifest.chunkID], "Otherwise eligible audio did not expire after ReceiptApplied")
            try require(try await phone.expireAudio(olderThan: cutoff, replayFloors: floors).isEmpty, "Repeated expiry was not idempotent")
        }
        report.receipt = applied.receipt; report.applied = applied
        try emit(report)
    }
}
