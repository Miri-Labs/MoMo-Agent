import Foundation
import Testing
import MoMoContracts
@testable import MoMoLink

struct AudioBlockReplyGateTests {
    @Test func controlDeadlineReleasesItsSlotAndALateSDKCallbackCannotCompleteTheAttemptTwice() async throws {
        let gate = LinkReplyGate<Bool>()
        let timeout = NSError(domain: "WCErrorDomain", code: 7012)
        do {
            let _: Bool = try await withCheckedThrowingContinuation { continuation in
                #expect(gate.install(continuation))
                gate.startDeadline(after: .milliseconds(10), failure: timeout)
            }
            Issue.record("Expected the application deadline")
        } catch {
            #expect((error as NSError).domain == "WCErrorDomain" && (error as NSError).code == 7012)
        }
        #expect(!gate.finish(.success(true)))
    }
    @Test func cancellationBeforeContinuationInstallationDoesNotSendOrHang() async throws {
        let gate = AudioBlockReplyGate()
        gate.finish(.failure(CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(!gate.install(continuation))
            } as AudioBlockReply
        }
    }

    @Test func noSDKCallbackStillReleasesTheInFlightSlotAtTheDeadline() async throws {
        let gate = AudioBlockReplyGate()
        await #expect(throws: AudioBlockTransferError.timedOut) {
            try await withCheckedThrowingContinuation { continuation in
                #expect(gate.install(continuation))
                gate.startDeadline(after: .milliseconds(10))
            } as AudioBlockReply
        }
        // A late callback cannot resume a second time.
        gate.finish(.failure(AudioBlockTransferError.rejected))
    }

    @Test func aLateFailureCannotReplaceTheFirstReply() async throws {
        let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: UUID(), epochID: UUID(),
            sourceDeviceID: UUID(), sourceBuild: "tests", sequence: 0, frames: FrameRange(start: 0, count: 8),
            timebaseHz: 16_000, wallClockAnchor: Date(), timezoneOffset: 0, codec: .pcmInt16,
            sampleRate: 16_000, channels: 1, decodedFrameCount: 8, byteCount: 16,
            audioSHA256: ContentHash.sha256(Data(repeating: 0, count: 16)), sourceKind: .fixture))
        let block = try AudioBlock(receiverDeviceID: UUID(), libraryInstanceID: UUID(), envelope: envelope, offset: 0, payload: Data())
        let gate = AudioBlockReplyGate()
        let reply: AudioBlockReply = try await withCheckedThrowingContinuation { continuation in
            #expect(gate.install(continuation))
            gate.startDeadline(after: .seconds(1))
            gate.finish(.success(AudioBlockReply(block: block, nextOffset: 0)))
            gate.finish(.failure(AudioBlockTransferError.timedOut))
        }
        #expect(reply.chunkID == envelope.manifest.chunkID)
    }
}
