import Foundation
import Testing
@testable import MoMoRecording

struct CaptureProgressDeliveryTests {
    @Test func hiddenHourKeepsSamplesAndSealsWithoutSecondBySecondNotifications() throws {
        let delivery = CaptureProgressDelivery(presentationActive: false)
        var notifications = 0, seals = 0
        for index in 1...18_000 {
            let sealed = index.isMultiple(of: 300)
            let frames = Int64(index) * 3_200
            if delivery.receive(CaptureProgress(frames: frames, uptime: Double(index) / 5,
                sealedChunkID: sealed ? UUID() : nil, normalizedLevel: 0)) {
                notifications += 1
                let update = try #require(delivery.take())
                if update.hasSealedChunk { seals += 1 }
            }
            #expect(delivery.latest?.frames == frames)
            #expect(delivery.lastReceivedAt != nil)
        }
        #expect(notifications == 61)
        #expect(seals == 60)
        delivery.finish()
    }

    @Test func wristRaiseImmediatelyDeliversLatestPositionAndRetainsPendingSeal() async throws {
        let delivery = CaptureProgressDelivery(presentationActive: false)
        var iterator = delivery.updates.makeAsyncIterator()
        delivery.receive(CaptureProgress(frames: 100, uptime: 1, sealedChunkID: nil, normalizedLevel: 0))
        _ = await iterator.next(); _ = delivery.take()
        #expect(!delivery.receive(CaptureProgress(frames: 48_000, uptime: 4, sealedChunkID: nil, normalizedLevel: 0)))
        delivery.setPresentationActive(true)
        #expect(await iterator.next() != nil)
        #expect(try #require(delivery.take()).progress.frames == 48_000)
        #expect(delivery.receive(CaptureProgress(frames: 64_000, uptime: 5, sealedChunkID: nil, normalizedLevel: 0)))
        _ = await iterator.next(); _ = delivery.take()
        delivery.setPresentationActive(false)
        #expect(!delivery.receive(CaptureProgress(frames: 80_000, uptime: 6, sealedChunkID: nil, normalizedLevel: 0)))
        delivery.receive(CaptureProgress(frames: 96_000, uptime: 7, sealedChunkID: UUID(), normalizedLevel: 0))
        delivery.setPresentationActive(true)
        #expect(try #require(delivery.take()).hasSealedChunk)
        delivery.finish()
    }

    @Test func hourOfCaptureKeepsEveryObservationAndEverySealedChunk() throws {
        let delivery = CaptureProgressDelivery()
        var notifications = 0, seals = 0
        for index in 1...18_000 {
            let sealed = index.isMultiple(of: 300)
            let frames = Int64(index) * 3_200
            let previousObservation = delivery.lastReceivedAt
            let notified = delivery.receive(CaptureProgress(frames: frames, uptime: Double(index) / 5,
                sealedChunkID: sealed ? UUID() : nil, normalizedLevel: 0.1))
            #expect(delivery.latest?.frames == frames, "Marks must see the latest position between display updates.")
            #expect(delivery.lastReceivedAt! >= (previousObservation ?? 0), "The watchdog observes every callback.")
            if notified {
                notifications += 1
                let update = try #require(delivery.take())
                #expect(update.progress.frames == frames)
                #expect(update.hasSealedChunk == sealed)
                if update.hasSealedChunk { seals += 1 }
            }
        }
        #expect(notifications == 3_601)
        #expect(seals == 60)
        #expect(delivery.latest?.frames == 57_600_000)
        delivery.finish()
    }

    @Test func firstSamplesAndShortSealedChunksBypassDisplayCoalescing() throws {
        let delivery = CaptureProgressDelivery()
        #expect(delivery.receive(CaptureProgress(frames: 0, uptime: 1, sealedChunkID: nil, normalizedLevel: 0)))
        _ = delivery.take()
        #expect(delivery.receive(CaptureProgress(frames: 64, uptime: 1.2, sealedChunkID: nil, normalizedLevel: 0)))
        #expect(try #require(delivery.take()).progress.frames == 64)
        #expect(!delivery.receive(CaptureProgress(frames: 128, uptime: 1.4, sealedChunkID: nil, normalizedLevel: 0)))
        #expect(delivery.receive(CaptureProgress(frames: 200, uptime: 1.6, sealedChunkID: UUID(), normalizedLevel: 0)))
        #expect(!delivery.receive(CaptureProgress(frames: 240, uptime: 1.8, sealedChunkID: nil, normalizedLevel: 0)))
        let update = try #require(delivery.take())
        #expect(update.progress.frames == 240 && update.hasSealedChunk)
        #expect(delivery.take() == nil)
        #expect(delivery.latest?.frames == 240)
        delivery.finish()
    }

    @Test(arguments: [true, false]) func finishingFlushesTheUnpublishedTailBeforeEnding(presentationActive: Bool) async throws {
        let delivery = CaptureProgressDelivery(presentationActive: presentationActive)
        var iterator = delivery.updates.makeAsyncIterator()
        delivery.receive(CaptureProgress(frames: 64, uptime: 1, sealedChunkID: nil, normalizedLevel: 0))
        _ = await iterator.next()
        _ = delivery.take()
        #expect(!delivery.receive(CaptureProgress(frames: 128, uptime: 1.2, sealedChunkID: nil, normalizedLevel: 0)))
        delivery.finish()
        delivery.finish()
        let final: Void? = await iterator.next()
        #expect(final != nil)
        #expect(try #require(delivery.take()).progress.frames == 128)
        let end: Void? = await iterator.next()
        #expect(end == nil)
        #expect(!delivery.receive(CaptureProgress(frames: 192, uptime: 1.4, sealedChunkID: nil, normalizedLevel: 0)))
        #expect(delivery.latest?.frames == 128)
    }
}
