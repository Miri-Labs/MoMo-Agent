import Foundation
import Testing
@testable import PhonePipelineReplay

struct TranscriptionRefreshGateTests {
    @Test func duplicateIdleNotificationsDoNotRefreshTheLibraryAgain() {
        var gate = TranscriptionRefreshGate()
        let first = gate.shouldRefresh(completedNewWindow: false, settled: true)
        #expect(first)
        for _ in 0..<100 {
            let repeated = gate.shouldRefresh(completedNewWindow: false, settled: true)
            #expect(!repeated)
        }
        let working = gate.shouldRefresh(completedNewWindow: false, settled: false)
        let finished = gate.shouldRefresh(completedNewWindow: false, settled: true)
        let newWindow = gate.shouldRefresh(completedNewWindow: true, settled: true)
        #expect(!working && finished && newWindow)
    }
    @Test func progressRefreshIsBoundedButCompletionAndNextRecordingAreImmediate() {
        var gate = TranscriptionRefreshGate()
        let start = ContinuousClock.now
        let initial = gate.shouldRefresh(completedNewWindow: false, settled: false, now: start)
        #expect(!initial)
        let first = gate.shouldRefresh(completedNewWindow: true, settled: false, now: start)
        #expect(first)
        for offset in 1..<1_000 {
            let intermediate = gate.shouldRefresh(completedNewWindow: true, settled: false, now: start + .milliseconds(offset))
            #expect(!intermediate)
        }
        let nextSecond = gate.shouldRefresh(completedNewWindow: true, settled: false, now: start + .seconds(1))
        #expect(nextSecond)
        let final = gate.shouldRefresh(completedNewWindow: false, settled: true, now: start + .milliseconds(1_001))
        #expect(final)
        let nextRecording = gate.shouldRefresh(completedNewWindow: true, settled: false, now: start + .milliseconds(1_002))
        #expect(nextRecording)
    }
}
