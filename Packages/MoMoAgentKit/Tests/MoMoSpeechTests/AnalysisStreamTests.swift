import Foundation
import Testing
import MoMoContracts
@testable import MoMoSpeech

struct AnalysisStreamTests {
    @Test(.timeLimit(.minutes(1))) func demandModeWaitsForConsumptionAndCancellationWakesProducer() async throws {
        let attempt = SpeechAttempt()
        let channel = SpeechAnalysisChannel(attempt: attempt, readAheadAllowed: false, onCancel: {})
        let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "test")
        let sent = AsyncStream<Int>.makeStream()
        let producer = Task {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    defer { sent.continuation.finish(); done.resume() }
                    do {
                        for index in 0..<3 {
                            try channel.waitForDemand(recorder: recorder)
                            try channel.send(.init(batch: .init(windows: [], analyzedCoverage: [], noSpeechCoverage: [],
                                checkpoint: nil, waitingForMoreAudio: false), isFinal: index == 2))
                            sent.continuation.yield(index)
                        }
                        channel.finish(.success(()))
                    } catch {
                        #expect((error as? SpeechError) == .cancelled)
                        channel.finish(.failure(error))
                    }
                }
            }
        }
        let stream = SpeechAnalysisStream(state: channel, producer: producer)
        let first = try #require(await stream.next())
        #expect(!first.isFinal)
        var signals = sent.stream.makeAsyncIterator()
        #expect(await signals.next() == 0)
        attempt.cancel()
        await stream.waitUntilFinished()
        #expect(await signals.next() == nil)
        await #expect(throws: CancellationError.self) { try await stream.next() }
    }

    @Test(.timeLimit(.minutes(1))) func abandonedReadAheadCanBeCancelledWithoutAConsumer() async throws {
        let attempt = SpeechAttempt()
        let channel = SpeechAnalysisChannel(attempt: attempt, readAheadAllowed: true, onCancel: {})
        let sent = AsyncStream<Void>.makeStream()
        let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "test")
        let producer = Task {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    defer { done.resume() }
                    do {
                        try channel.waitForDemand(recorder: recorder)
                        try channel.send(.init(batch: .init(windows: [], analyzedCoverage: [], noSpeechCoverage: [],
                            checkpoint: nil, waitingForMoreAudio: false), isFinal: false))
                        sent.continuation.yield(())
                        try channel.waitForDemand(recorder: recorder)
                        Issue.record("Producer passed a full one-page buffer without consumption")
                        channel.finish(.success(()))
                    } catch { channel.finish(.failure(error)) }
                }
            }
        }
        var stream: SpeechAnalysisStream? = SpeechAnalysisStream(state: channel, producer: producer)
        for await _ in sent.stream { break }
        #expect(stream != nil)
        stream = nil
        await producer.value
        #expect(attempt.cancellationUptimeNanoseconds != nil)
    }

    @Test func audioBufferKeepsOnlyItsBoundedTail() throws {
        var buffer = AnalysisAudioBuffer(capacity: 8)
        buffer.append([0, 1, 2, 3, 4, 5])
        buffer.append([6, 7, 8, 9])
        #expect(buffer.samples(in: try FrameRange(start: 0, count: 2)) == nil)
        #expect(buffer.samples(in: try FrameRange(start: 2, count: 8)) == [2, 3, 4, 5, 6, 7, 8, 9])
        buffer.append((10..<22).map(Float.init))
        #expect(buffer.samples(in: try FrameRange(start: 14, count: 8)) == (14..<22).map(Float.init))
    }
}
