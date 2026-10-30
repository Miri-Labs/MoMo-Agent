import Foundation
import Testing
@testable import MoMoArchive

struct WaveformPreparationTests {
    @Test func completionSurvivesRestartAndNewAudioStillEntersQueue() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store(), cache = UUID()
        let old = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(old, to: store))
        let entry = try #require(await store.waveformPreparationPage(cacheGeneration: cache).first)
        try await store.completeWaveformPreparation(entry, cacheGeneration: cache)
        let reopened = try fixture.store()
        #expect(try await reopened.waveformPreparationPage(cacheGeneration: cache).isEmpty)
        let fresh = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await reopened.commitReceivedChunk(fixture.deliver(fresh, to: reopened))
        let pending = try await reopened.waveformPreparationPage(cacheGeneration: cache)
        #expect(pending.count == 1 && pending[0].timeline.parts[0].manifest.chunkID == fresh.manifest.chunkID)
        #expect(try await reopened.waveformPreparationPage(cacheGeneration: UUID()).count == 2,
            "Purging the cache must make all previews eligible again.")
        // An interrupted preparation has no receipt and stays eligible after another restart.
        #expect(try await fixture.store().waveformPreparationPage(cacheGeneration: cache).count == 1)
    }
}
