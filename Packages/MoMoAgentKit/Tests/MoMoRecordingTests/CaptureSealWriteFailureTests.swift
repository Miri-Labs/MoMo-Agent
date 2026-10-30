import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct CaptureSealWriteFailureTests {
    @Test func realSealPublicationFailurePreservesUnacknowledgedAudioAndRecoversDraft() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let manifest = fixture.envelope.manifest
        let store = try fixture.store()
        let spool = fixture.root.appendingPathComponent("capture")
        let epoch = spool.appendingPathComponent(manifest.sessionID.uuidString).appendingPathComponent(manifest.epochID.uuidString)
        let writer = try AACSegmentWriter(directory: epoch,
            sessionID: manifest.sessionID, epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID,
            sourceBuild: "write-failure-tests", sourceKind: .fixture, inputSampleRate: 16_000,
            targetSeconds: 1, wallClockAnchor: manifest.wallClockAnchor, timezoneOffset: 0)
        let originalPermissions = try #require(FileManager.default.attributesOfItem(atPath: epoch.path)[.posixPermissions] as? NSNumber)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: epoch.path) }
            catch { Issue.record("Could not restore capture fixture permissions: \(error)") }
        }
        var sealed: [EncodedChunk] = []
        for _ in 0..<4 { sealed += try writer.append(Array(repeating: 0.1, count: 4_000)) }
        let first = try #require(sealed.first)
        let recorded = try await store.sealChunk(audioAt: first.audioURL, envelope: first.envelope)
        _ = try writer.append(Array(repeating: 0.2, count: 4_000))
        var failedAudio: URL?
        writer.sealCheckpoint = { step, audio in
            if case .afterContainerClose = step {
                failedAudio = audio
                // The hook does not throw. The subsequent production sidecar write
                // must fail in Foundation after real AAC container finalization.
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: epoch.path)
            }
        }
        var failure: NSError?
        do { _ = try writer.finish(); Issue.record("Expected sealed sidecar publication to fail") }
        catch { failure = error as NSError }
        #expect(failure?.domain == NSCocoaErrorDomain)
        #expect(failure?.code == CocoaError.fileWriteNoPermission.rawValue)
        let audio = try #require(failedAudio)
        let draftData = try Data(contentsOf: SealedCaptureSpool.draftURL(for: audio))
        let draft = try WireJSON.decode(CaptureDraft.self, from: draftData)
        let recoveredEnvelope = try draft.envelope(audioURL: audio)
        #expect(recoveredEnvelope.manifest.frames == (try FrameRange(start: 16_000, count: 4_000)))
        #expect(!FileManager.default.fileExists(atPath: SealedCaptureSpool.sidecar(for: audio).path))
        #expect(try await store.pendingChunkCount() == 1)
        #expect(try await store.pendingReceiptApplications().isEmpty)
        #expect(try ContentHash.sha256(fileAt: recorded.audioURL) == first.envelope.manifest.audioSHA256)
        let failedAudioHash = try ContentHash.sha256(fileAt: audio)
        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: epoch.path)

        let reopened = try fixture.store()
        _ = try await reopened.recover()
        let recovery = try await CaptureSpool.recover(directory: spool, store: reopened)
        #expect(recovery.incompleteFiles.isEmpty && recovery.damagedFiles.isEmpty)
        #expect(recovery.recovered.contains(recoveredEnvelope.manifest.chunkID))
        let pending = try await reopened.pendingChunks()
        #expect(pending.count == 2)
        #expect(pending.map(\.envelope.manifest.frames) == [try FrameRange(start: 0, count: 16_000), try FrameRange(start: 16_000, count: 4_000)])
        let tail = try #require(pending.first { $0.envelope.manifest.chunkID == recoveredEnvelope.manifest.chunkID })
        #expect(try ContentHash.sha256(fileAt: tail.audioURL) == failedAudioHash)
        #expect(try ContentHash.sha256(fileAt: recorded.audioURL) == first.envelope.manifest.audioSHA256)
        #expect(try await CaptureSpool.recover(directory: spool, store: reopened).recovered.isEmpty)
        #expect(try await reopened.pendingChunkCount() == 2)
    }
}
