#if DEBUG && os(macOS)
import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveReceiveBoundaryTests {
    @Test func observationsMatchRealFileAndTransactionBoundaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let source = fixture.root.appendingPathComponent("delivery.wav")
        try fixture.audio.write(to: source)
        let inboxURL = store.inbox.rootURL
        let relative = await store.recordingDirectory(manifest: envelope.manifest)
        let target = store.rootURL.appendingPathComponent(relative + "/audio/" + envelope.manifest.chunkID.uuidString + ".wav")
        let databaseURL = store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite")
        let observations = ReceiveBoundaryObservations()
        let observer: @Sendable (ArchiveReceiveBoundary) -> Void = { boundary in
            do {
                let items = try FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)
                guard let item = items.first else { throw ArchiveError.invalidInbox }
                let database = try ArchiveDatabase(url: databaseURL)
                let count = try database.rows("SELECT (SELECT COUNT(*) FROM chunks),(SELECT COUNT(*) FROM transcription_jobs),(SELECT COUNT(*) FROM receipt_outbox)").first
                guard let count else { throw ArchiveError.database(11) }
                observations.append(ReceiveBoundaryObservation(boundary: boundary,
                    sourceExists: FileManager.default.fileExists(atPath: source.path),
                    inboxManifestExists: FileManager.default.fileExists(atPath: item.appendingPathComponent("manifest.json").path),
                    inboxAudioExists: FileManager.default.fileExists(atPath: item.appendingPathComponent("audio").path),
                    targetExists: FileManager.default.fileExists(atPath: target.path),
                    sidecarExists: FileManager.default.fileExists(atPath: target.appendingPathExtension("manifest.json").path),
                    chunkCount: try count.requireInt(0), jobCount: try count.requireInt(1), receiptCount: try count.requireInt(2)))
            } catch { observations.fail(String(describing: error)) }
        }
        let inbox = try InboxCustodian(rootURL: inboxURL, receiveObserver: observer)
        await store.setReceiveBoundaryObserver(observer)
        let item = try inbox.preserve(fileURL: source, envelope: envelope)
        guard case .accepted(let receipt) = try await store.commitReceivedChunk(item) else { Issue.record("Expected committed receipt"); return }
        let (events, failures) = observations.snapshot()
        #expect(failures.isEmpty)
        #expect(events.map(\.boundary) == [.inboxManifestSynced, .originalsStoredBeforeCommit, .receiveCommitted])
        #expect(events.map(\.chunkCount) == [0, 0, 1])
        #expect(events.map(\.jobCount) == [0, 0, 1])
        #expect(events.map(\.receiptCount) == [0, 0, 1])
        #expect(events.map(\.sourceExists) == [true, false, false])
        #expect(events.map(\.inboxManifestExists) == [true, true, true])
        #expect(events.allSatisfy { !$0.inboxAudioExists })
        #expect(events.map(\.targetExists) == [false, true, true])
        #expect(events.map(\.sidecarExists) == [false, true, true])
        #expect(!FileManager.default.fileExists(atPath: item.directoryURL.path))
        let reopened = try fixture.store()
        #expect(try await reopened.pendingReceipts() == [receipt])
        await store.setReceiveBoundaryObserver()
    }
}

private struct ReceiveBoundaryObservation: Sendable {
    let boundary: ArchiveReceiveBoundary
    let sourceExists: Bool
    let inboxManifestExists: Bool
    let inboxAudioExists: Bool
    let targetExists: Bool
    let sidecarExists: Bool
    let chunkCount: Int64
    let jobCount: Int64
    let receiptCount: Int64
}

private final class ReceiveBoundaryObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ReceiveBoundaryObservation] = []
    private var failures: [String] = []
    func append(_ event: ReceiveBoundaryObservation) { lock.withLock { events.append(event) } }
    func fail(_ message: String) { lock.withLock { failures.append(message) } }
    func snapshot() -> ([ReceiveBoundaryObservation], [String]) { lock.withLock { (events, failures) } }
}
#endif
