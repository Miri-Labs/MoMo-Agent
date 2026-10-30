import Darwin
import Foundation
import MoMoArchive
import MoMoContracts
import MoMoRecording

struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ReplayFailure(description: message) }
}

func emit<T: Encodable>(_ value: T) throws {
    var data = try WireJSON.encode(value)
    data.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: data)
}

struct Fixture: Codable {
    let receiverDeviceID: UUID
    let libraryInstanceID: UUID
    let envelope: ManifestEnvelope
    let watchAudioRelativePath: String
}

struct InboxOutcome: Codable {
    let itemID: UUID
    let state: String
    let receipt: Receipt?
}

struct PhaseReport: Encodable {
    let phase: String
    let processID: Int32 = getpid()
    var inbox: [InboxOutcome] = []
    var receiptsBeforeRetransmission: [Receipt] = []
    var retransmission: String?
    var receipt: Receipt?
    var applied: ReceiptApplied?
    var pendingInboxCount: Int?
    var watchState: String?
}

@main enum CrashRecoveryReplay {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            try require(arguments.count == 3, "Usage: CrashRecoveryReplay PHASE CASE_DIRECTORY J08-a|b|c|d|e|f")
            #if DEBUG && os(macOS)
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            if arguments[2] == "J08-a" {
                try await SenderCrashReplay.capture(phase: arguments[0], root: root)
                return
            }
            if ["J08-e", "J08-f"].contains(arguments[2]) {
                if arguments[0] == "prepare" { try await prepare(root: root) }
                else { try await SenderCrashReplay.receipt(phase: arguments[0], root: root, boundary: arguments[2]) }
                return
            }
            guard let boundary = ArchiveReceiveBoundary(rawValue: arguments[2]) else {
                throw ReplayFailure(description: "Unknown receive boundary")
            }
            if arguments[0] == "prepare" {
                try await prepare(root: root)
                return
            }
            let fixture = try WireJSON.decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let phone = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverDeviceID)
            try require(phone.libraryInstanceID == fixture.libraryInstanceID, "Restart changed the archive library identity")
            switch arguments[0] {
            case "receive": try await receiveAtBoundary(root: root, fixture: fixture, phone: phone, boundary: boundary)
            case "recover": try await recover(root: root, fixture: fixture, phone: phone, boundary: boundary)
            case "duplicate": try await duplicateAndAcknowledge(root: root, fixture: fixture, phone: phone)
            case "verify": try await verifyRestart(root: root, fixture: fixture, phone: phone)
            default: throw ReplayFailure(description: "Unknown worker phase")
            }
            #else
            throw ReplayFailure(description: "This worker requires a Debug macOS build with production observation hooks")
            #endif
        } catch {
            do { try emit(["event": "failure", "message": String(describing: error)]) }
            catch { print("Cannot emit worker failure") }
            exit(1)
        }
    }

    private static func prepare(root: URL) async throws {
        let files = FileManager.default
        let configURL = root.appendingPathComponent("fixture.json")
        try require(!files.fileExists(atPath: configURL.path), "The fixture already exists")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionID = UUID(), epochID = UUID(), sourceID = UUID(), receiverID = UUID()
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input"),
            sessionID: sessionID, epochID: epochID, sourceDeviceID: sourceID,
            sourceBuild: "crash-recovery-replay-v1", sourceKind: .fixture, targetFrames: 32_000,
            wallClockAnchor: Date(timeIntervalSince1970: 1_792_022_400), timezoneOffset: 28_800)
        let samples = (0..<32_000).map { Int16(($0 % 2_000) - 1_000) }
        let encoded = try writer.append(samples)
        let tail = try writer.finish()
        try require(encoded.count == 1 && tail == nil, "Fixture did not seal exactly one WAV")
        let watch = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
        let phone = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: receiverID)
        try await watch.bindReceiver(deviceID: receiverID, libraryInstanceID: phone.libraryInstanceID)
        let chunk = try await watch.sealChunk(audioAt: encoded[0].audioURL, envelope: encoded[0].envelope)
        let fixture = Fixture(receiverDeviceID: receiverID, libraryInstanceID: phone.libraryInstanceID,
            envelope: chunk.envelope,
            watchAudioRelativePath: "watch/CaptureReady/\(chunk.envelope.manifest.chunkID.uuidString)/audio")
        try require(try ContentHash.sha256(fileAt: root.appendingPathComponent(fixture.watchAudioRelativePath)) == chunk.envelope.manifest.audioSHA256,
                    "The independent fixture path does not identify the sealed original")
        try WireJSON.encode(fixture).write(to: configURL, options: .withoutOverwriting)
        try emit(PhaseReport(phase: "prepare"))
    }

    #if DEBUG && os(macOS)
    private static func receiveAtBoundary(root: URL, fixture: Fixture, phone: ArchiveStore,
                                          boundary: ArchiveReceiveBoundary) async throws {
        struct BoundaryEvent: Encodable { let event = "boundary"; let boundary: ArchiveReceiveBoundary; let processID: Int32 }
        let observer: @Sendable (ArchiveReceiveBoundary) -> Void = { observed in
            guard observed == boundary else { return }
            do { try emit(BoundaryEvent(boundary: observed, processID: getpid())) }
            catch { exit(70) }
            // The parent verifies SIGSTOP before sending SIGKILL. This callback does not modify archive state.
            guard raise(SIGSTOP) == 0 else { exit(71) }
            exit(72) // Continuing the stopped worker would invalidate the crash experiment.
        }
        await phone.setReceiveBoundaryObserver(observer)
        let inbox = try InboxCustodian(rootURL: phone.inbox.rootURL, receiveObserver: observer)
        let delivery = try copyDelivery(root: root, fixture: fixture, name: "first.wav")
        let item = try inbox.preserve(fileURL: delivery, envelope: fixture.envelope)
        _ = try await phone.commitReceivedChunk(item)
        throw ReplayFailure(description: "The requested boundary did not stop the process")
    }

    private static func recover(root: URL, fixture: Fixture, phone: ArchiveStore,
                                boundary: ArchiveReceiveBoundary) async throws {
        try await phone.recoverInterruptedJobs()
        try await phone.recoverPendingExpirations()
        var report = PhaseReport(phase: "recover")
        report.inbox = try await inspectInbox(phone)
        if boundary == .inboxManifestSynced {
            try require(report.inbox.isEmpty, "An unpublished handoff must wait for redelivery outside the processing queue")
        } else {
            try require(report.inbox.count == 1, "Restart must find the original published inbox item")
            let expected = boundary == .originalsStoredBeforeCommit ? "accepted" : "duplicate"
            try require(report.inbox[0].state == expected, "Unexpected first recovery result: \(report.inbox[0].state)")
        }
        report.receiptsBeforeRetransmission = try await phone.pendingReceipts()
        try require(report.receiptsBeforeRetransmission.count == (boundary == .inboxManifestSynced ? 0 : 1),
                    "Recovery acknowledged an incomplete handoff or lost a durable receipt")
        let watch = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
        let recovery = try await watch.recover()
        try require(recovery.missing.isEmpty && recovery.damaged.isEmpty && recovery.unfinished.isEmpty, "Watch original did not survive")
        try require(try await watch.cleanupAcknowledgedChunks().isEmpty, "The unacknowledged Watch original was deleted")
        let item = try phone.inbox.preserve(fileURL: copyDelivery(root: root, fixture: fixture, name: "retry.wav"), envelope: fixture.envelope)
        let (state, receipt) = try successful(try await phone.commitReceivedChunk(item))
        try require(state == (boundary == .inboxManifestSynced ? "accepted" : "duplicate"), "Retransmission was not idempotent")
        try require(receipt.matches(fixture.envelope), "Recovered receipt identifies different content")
        if let original = report.receiptsBeforeRetransmission.first {
            try require(original == receipt, "Retransmission changed the durable receipt")
        }
        try require(try await phone.pendingReceipts() == [receipt], "Exactly one receipt must be ready for delivery")
        report.retransmission = state; report.receipt = receipt
        report.pendingInboxCount = try phone.inbox.pendingItems().count
        report.watchState = try await watch.chunk(id: fixture.envelope.manifest.chunkID)?.state.rawValue
        try require(report.watchState == "ready", "Watch cleared audio before its business receipt arrived")
        try require(report.pendingInboxCount == 0, "Recovery left a failed handoff in the processing queue")
        try emit(report)
    }
    #endif

    private static func duplicateAndAcknowledge(root: URL, fixture: Fixture, phone: ArchiveStore) async throws {
        let pending = try await phone.pendingReceipts()
        try require(pending.count == 1, "Receipt did not survive another process restart")
        let item = try phone.inbox.preserve(fileURL: copyDelivery(root: root, fixture: fixture, name: "duplicate.wav"), envelope: fixture.envelope)
        let (state, receipt) = try successful(try await phone.commitReceivedChunk(item))
        try require(state == "duplicate" && pending[0] == receipt, "Repeated delivery changed the receipt")
        let watch = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
        let application = try await watch.applyReceipt(receipt)
        try require(try await watch.applyReceipt(receipt) == application, "Repeated receipt changed ReceiptApplied")
        try await phone.applyReceipt(application)
        try await phone.applyReceipt(application)
        try require(try await watch.cleanupAcknowledgedChunks() == [fixture.envelope.manifest.chunkID], "Acknowledged original was not cleaned exactly once")
        try require(try await watch.cleanupAcknowledgedChunks().isEmpty, "Repeated cleanup removed another original")
        try require(try await phone.pendingReceipts().isEmpty, "ReceiptApplied did not close the phone outbox")
        var report = PhaseReport(phase: "duplicate")
        report.retransmission = state; report.receipt = receipt; report.applied = application
        report.watchState = try await watch.chunk(id: fixture.envelope.manifest.chunkID)?.state.rawValue
        try emit(report)
    }

    private static func verifyRestart(root: URL, fixture: Fixture, phone: ArchiveStore) async throws {
        try await phone.recoverInterruptedJobs()
        var report = PhaseReport(phase: "verify")
        report.inbox = try await inspectInbox(phone)
        try require(report.inbox.isEmpty, "Unexpected inbox recovery after retransmission")
        report.receiptsBeforeRetransmission = try await phone.pendingReceipts()
        try require(report.receiptsBeforeRetransmission.isEmpty, "An incomplete handoff replayed a receipt")
        let watch = try RecordingStore(rootURL: root.appendingPathComponent("watch"))
        let recovery = try await watch.recover()
        try require(recovery.missing.isEmpty && recovery.damaged.isEmpty, "Restart damaged the sender ledger")
        let applications = try await watch.pendingReceiptApplications()
        try require(applications.count == 1 && applications[0].receipt.matches(fixture.envelope), "ReceiptApplied was lost after sender audio cleanup")
        try await phone.applyReceipt(applications[0])
        try require(try await phone.pendingReceipts().isEmpty, "Replayed ReceiptApplied did not close the outbox")
        try require(try phone.inbox.pendingItems().isEmpty, "Recovered incomplete handoff remained in Inbox")
        report.applied = applications[0]
        report.watchState = try await watch.chunk(id: fixture.envelope.manifest.chunkID)?.state.rawValue
        try require(report.watchState == "removed", "Sender audio was resurrected")
        try emit(report)
    }

    private static func inspectInbox(_ phone: ArchiveStore) async throws -> [InboxOutcome] {
        try await phone.processInbox().map { item in
            switch item.result {
            case .success(let result):
                let (state, receipt) = try successful(result)
                return InboxOutcome(itemID: item.itemID, state: state, receipt: receipt)
            case .failure(let error):
                guard let error = error as? ArchiveError, error == .invalidInbox else { throw error }
                return InboxOutcome(itemID: item.itemID, state: "invalidInbox", receipt: nil)
            }
        }
    }

    private static func successful(_ result: ReceiveResult) throws -> (String, Receipt) {
        switch result {
        case .accepted(let receipt): return ("accepted", receipt)
        case .duplicate(let receipt): return ("duplicate", receipt)
        case .restored(let receipt): return ("restored", receipt)
        case .deleted, .expired, .missing, .noLongerPending: throw ReplayFailure(description: "Unexpected receive outcome")
        }
    }

    private static func copyDelivery(root: URL, fixture: Fixture, name: String) throws -> URL {
        let directory = root.appendingPathComponent("Delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: root.appendingPathComponent(fixture.watchAudioRelativePath), to: url)
        return url
    }
}
