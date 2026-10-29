import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct VoiceprintTests {
    @Test func mergedReadingTurnCorrectsAndPlaysAllItsMembersAtomically() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await append(vector(), fixture: fixture, store: store, index: 0)
        let document = try await append(vector(), fixture: fixture, store: store, index: 1)
        let locations = try await store.transcriptLocations(document: document)
        let turn = try #require(document.readingTurns(locations: locations).first)
        #expect(document.readingTurns(locations: locations).count == 1)
        #expect(turn.sources.count == 2)
        let playback = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: document.generation,
            source: turn.source, additionalSources: Array(turn.sources.dropFirst()))
        #expect(playback.parts.map(\.frames.count).reduce(0, +) == 128_000)
        try await store.correctSpeakers(turn.sources, feedback: .owner)
        let corrected = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(corrected.spans.allSatisfy { $0.attribution?.isUser == true && $0.attribution?.confirmed == true })
        #expect(corrected.version == document.version + 1)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.correctSpeakers(turn.sources, feedback: .notOwner)
        }
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).version == corrected.version)
    }

    private let revision = ContentHash.sha256(Data("speaker-v1".utf8))
    private func vector(_ x: Float = 1, _ y: Float = 0) -> [Float] {
        let norm = sqrt(x * x + y * y)
        return [x / norm, y / norm] + Array(repeating: 0, count: 254)
    }

    @Test func feedbackSurvivesRestartAndCorrectsBothFalsePositiveAndFalseNegative() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        #expect(first.spans.last?.attribution?.isUser == false)
        try await store.correctSpeaker(first.source(for: first.spans.last!), feedback: .owner)
        let second = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 1)
        #expect(second.spans.last?.attribution?.isUser == true)
        #expect(second.spans.last?.attribution?.confirmed == false)
        try await store.correctSpeaker(second.source(for: second.spans.last!), feedback: .notOwner)
        let corrected = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(corrected.spans.last?.attribution?.isUser == false)
        #expect(corrected.spans.first?.attribution?.isUser == true)
        let reopened = try fixture.store()
        let third = try await append(vector(0.8, 0.6), fixture: fixture, store: reopened, index: 2)
        #expect(third.spans.last?.attribution?.isUser == false)
        // A contradictory correction replaces the old negative exemplar for that exact source.
        let negative = third.spans[1]
        try await reopened.correctSpeaker(third.source(for: negative), feedback: .owner)
        let repaired = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(repaired.spans[1].attribution?.confirmed == true)
        #expect(repaired.spans.last?.attribution?.isUser == true)
        // Remove the original clean anchor. Only the user's second confirmation remains.
        try await reopened.correctSpeaker(repaired.source(for: repaired.spans[0]), feedback: .clear)
        let current = try await reopened.readTranscript(sessionID: fixture.sessionID)
        let ownerID = try #require(current.spans[1].attribution?.personID)
        try await reopened.forgetVoiceprint(personID: ownerID)
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans.allSatisfy { $0.attribution?.personID == nil })
    }

    @Test func inferredSpeechNeverBecomesAnAnchorAndModelRevisionsDoNotMix() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .owner)
        _ = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 1)
        let third = try await append(vector(0.6, 0.8), fixture: fixture, store: store, index: 2)
        #expect(third.spans.last?.attribution?.personID == nil)
        let fourth = try await append(vector(), fixture: fixture, store: store, index: 3, model: ContentHash.sha256(Data("v2".utf8)))
        #expect(fourth.spans.last?.attribution?.personID == nil)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .notOwner)
        }
    }

    @Test func deletingEvidenceRemovesItsLearningAndShortSpeechCannotTrain() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let other = try Fixture(); defer { other.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .owner)
        let second = try await append(vector(), fixture: other, store: store, index: 0)
        #expect(second.spans[0].attribution?.isUser == true)
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(try await store.readTranscript(sessionID: other.sessionID).spans[0].attribution?.isUser == false)
        let short = try await append(vector(), fixture: other, store: store, index: 1, seconds: 1.5)
        try await store.correctSpeaker(short.source(for: short.spans.last!), feedback: .owner)
        #expect(try await store.readTranscript(sessionID: other.sessionID).spans.last?.attribution?.confirmed == true)
        let following = try await append(vector(), fixture: other, store: store, index: 2)
        #expect(following.spans.last?.attribution?.isUser == false)
    }

    @Test func ambiguousPeopleAndKnownNegativeStayUnknown() {
        let a = UUID(), b = UUID()
        #expect(VoiceprintMatcher.match(vector(), examples: [
            .init(person: a, embedding: vector(), positive: true),
            .init(person: b, embedding: vector(0.99, 0.1), positive: true)]) == nil)
        #expect(VoiceprintMatcher.match(vector(), examples: [
            .init(person: a, embedding: vector(), positive: true),
            .init(person: a, embedding: vector(), positive: false)]) == nil)
    }

    @Test func shortSpeechDoesNotCreateOrMoveAnAnonymousAnchor() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let short = try await append(vector(), fixture: fixture, store: store, index: 0, seconds: 1.5)
        let long = try await append(vector(), fixture: fixture, store: store, index: 1)
        #expect(short.spans[0].attribution?.clusterID != long.spans[1].attribution?.clusterID)
        let inherited = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 2, seconds: 0)
        #expect(inherited.spans[2].attribution?.clusterID == long.spans[1].attribution?.clusterID)
        #expect(inherited.spans[2].attribution?.canLearn == false)
    }

    @Test func unknownWithoutVoiceprintCanBeCorrectedWithoutTraining() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let unknown = try await append([], fixture: fixture, store: store, index: 0)
        #expect(unknown.spans[0].attribution == nil)
        try await store.correctSpeaker(unknown.source(for: unknown.spans[0]), feedback: .owner)
        let marked = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(marked.spans[0].attribution?.isUser == true)
        #expect(marked.spans[0].attribution?.confirmed == true)
        #expect(marked.spans[0].attribution?.canLearn == false)
        #expect(marked.generation == unknown.generation)
        let reopened = try fixture.store()
        let following = try await append(vector(), fixture: fixture, store: reopened, index: 1)
        #expect(following.spans[0].attribution?.isUser == true)
        #expect(following.spans[1].attribution?.personID == nil)
        await #expect(throws: ArchiveError.staleSource) {
            try await reopened.correctSpeaker(unknown.source(for: unknown.spans[0]), feedback: .notOwner)
        }
        try await reopened.correctSpeaker(following.source(for: following.spans[0]), feedback: .notOwner)
        let rejected = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(rejected.spans[0].attribution?.isUser == false)
        try await reopened.correctSpeaker(rejected.source(for: rejected.spans[0]), feedback: .person("小林"))
        let named = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(named.spans[0].speaker == "小林")
        try await reopened.correctSpeaker(named.source(for: named.spans[0]), feedback: .notOwner)
        let stillNamed = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(stillNamed.spans[0].speaker == "小林")
        try await reopened.correctSpeaker(stillNamed.source(for: stillNamed.spans[0]), feedback: .clear)
        let cleared = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(cleared.spans[0].attribution?.personID == nil)
        try await reopened.correctSpeaker(cleared.source(for: cleared.spans[0]), feedback: .owner)
        let owner = try await reopened.readTranscript(sessionID: fixture.sessionID)
        try await reopened.forgetVoiceprint(personID: #require(owner.spans[0].attribution?.personID))
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans[0].attribution?.personID == nil)
    }

    private func append(_ embedding: [Float], fixture: Fixture, store: ArchiveStore, index: Int,
                        model: String? = nil, seconds: Double = 4) async throws -> TranscriptDocument {
        let fingerprint = ContentHash.sha256(Data("voiceprint-window".utf8))
        let envelope = try fixture.envelope(startFrame: Int64(index) * 64_000, frameCount: 64_000, sequence: Int64(index))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let manifest = envelope.manifest, frames = manifest.frames
        let window = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(fixture.sessionID)-\(index)".utf8)), sessionID: fixture.sessionID,
            epochID: fixture.epochID, analysisAnchor: ticket.checkpoint?.sourceFrame ?? 0, coreFrames: frames, contextFrames: frames,
            modelCoreFrames: try FrameRange(start: frames.start - (ticket.checkpoint?.sourceFrame ?? 0), count: frames.count),
            modelContextFrames: try FrameRange(start: frames.start - (ticket.checkpoint?.sourceFrame ?? 0), count: frames.count),
            sources: [.init(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256, audioSHA256: manifest.audioSHA256, sourceFrames: frames)],
            configurationFingerprint: fingerprint)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window], analyzedCoverage: [frames], noSpeechCoverage: [],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceFrame: frames.end,
                configurationFingerprint: fingerprint), waitingForMoreAudio: true)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        return try await store.commitWindowTranscript(ticket: recognition, text: "声纹测试 \(index)", rawResult: Data(),
            speakerParts: [.init(text: "声纹测试 \(index)", frames: frames, evidence: .init(start: 0, end: 4, localSpeaker: 1,
                embedding: embedding, cleanSeconds: seconds, modelRevision: model ?? revision))])
    }
}
