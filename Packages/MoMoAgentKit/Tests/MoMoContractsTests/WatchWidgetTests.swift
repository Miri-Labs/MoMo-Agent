import Foundation
import Testing
@testable import MoMoContracts

private let widgetDate = Date(timeIntervalSince1970: 1_790_000_000)

private func widgetSnapshot(activity: WatchCaptureActivity = .recording, duration: Double = 73,
                            sampleAge: Double = 0, pending: Int? = 3) -> WatchWidgetSnapshot {
    WatchWidgetSnapshot(runtimeID: UUID(), generation: 7, observedAt: widgetDate, sessionID: UUID(),
        activity: activity, capturedDuration: duration, pendingChunkCount: pending,
        lastSampleAt: activity == .recording ? widgetDate.addingTimeInterval(-sampleAge) : nil)
}

@Test func watchWidgetExpiresFromActualSampleTimeAndNeverExtrapolatesDuration() throws {
    let snapshot = widgetSnapshot(sampleAge: 4)
    try snapshot.validate()
    #expect(snapshot.isFresh(at: widgetDate.addingTimeInterval(145)))
    #expect(!snapshot.isFresh(at: widgetDate.addingTimeInterval(146)))
    #expect(!snapshot.isFresh(at: widgetDate.addingTimeInterval(-6)))
    #expect(snapshot.capturedDuration == 73)
    #expect(!widgetSnapshot(sampleAge: 200).isFresh(at: widgetDate))
}

@Test func watchWidgetValidatesDecodedSnapshotsIncludingUnknownSchemas() throws {
    let valid = widgetSnapshot()
    #expect(try JSONDecoder().decode(WatchWidgetSnapshot.self, from: JSONEncoder().encode(valid)) == valid)
    for invalid in [widgetSnapshot(duration: -1), widgetSnapshot(duration: .infinity),
                    widgetSnapshot(sampleAge: -1), widgetSnapshot(pending: -1),
                    WatchWidgetSnapshot(runtimeID: UUID(), generation: 1, observedAt: widgetDate,
                        sessionID: nil, activity: .recording, capturedDuration: 1, pendingChunkCount: 0, lastSampleAt: nil)] {
        #expect(throws: WatchWidgetError.self) { try invalid.validate() }
    }
    let data = try JSONEncoder().encode(valid)
    let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
    let unsupported = try JSONDecoder().decode(WatchWidgetSnapshot.self, from: Data(text.utf8))
    #expect(throws: WatchWidgetError.self) { try unsupported.validate() }
}

@Test func watchWidgetKeepsUnknownQueueSeparateFromAnEmptyQueueDuringHistoryRecovery() throws {
    let snapshot = widgetSnapshot(pending: nil)
    try snapshot.validate()
    #expect(snapshot.activity == .recording)
    #expect(snapshot.isFresh(at: widgetDate))
    let restored = try JSONDecoder().decode(WatchWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(restored.pendingChunkCount == nil)
    #expect(widgetSnapshot(pending: 0).pendingChunkCount == 0)
}

@Test func watchWidgetActionsRoundTripAndRequireCurrentCaptureGeneration() throws {
    let snapshot = widgetSnapshot()
    for action in [WatchWidgetAction.start, .pause, .resume] {
        let request = snapshot.request(action)
        #expect(try WatchWidgetRequest(url: request.url) == request)
        #expect(request.matches(runtimeID: snapshot.runtimeID, generation: 7, sessionID: snapshot.sessionID))
        #expect(!request.matches(runtimeID: snapshot.runtimeID, generation: 8, sessionID: snapshot.sessionID))
        #expect(!request.matches(runtimeID: UUID(), generation: 7, sessionID: snapshot.sessionID))
        #expect(!request.matches(runtimeID: snapshot.runtimeID, generation: 7, sessionID: UUID()))
    }
    #expect(try WatchWidgetRequest(url: WatchWidgetRequest().url) == WatchWidgetRequest())
}

@Test func watchWidgetRejectsMalformedAndUnscopedControls() throws {
    for value in ["https://capture?action=start", "momoagent://capture/extra?action=open",
                  "momoagent://capture?action=toggle", "momoagent://capture?action=pause",
                  "momoagent://capture?action=open&action=start", "momoagent://capture?action=open&session=invalid",
                  "momoagent://capture?action=open#start", "momoagent://capture?action=open&extra=1",
                  "momoagent://capture?action=start&runtime=\(UUID())&generation=bad"] {
        let url = try #require(URL(string: value))
        #expect(throws: WatchWidgetError.self) { try WatchWidgetRequest(url: url) }
    }
}

@Test func watchWidgetBetaLinksCannotControlTheRelease() throws {
    let request = widgetSnapshot().request(.pause)
    let betaURL = request.url(scheme: "momoagent-beta")
    #expect(try WatchWidgetRequest(url: betaURL, expectedScheme: "momoagent-beta") == request)
    #expect(throws: WatchWidgetError.self) { try WatchWidgetRequest(url: betaURL) }
    #expect(throws: WatchWidgetError.self) {
        try WatchWidgetRequest(url: request.url, expectedScheme: "momoagent-beta")
    }
}

@Test func watchWidgetHeartbeatDoesNotTreatEveryNewAudioFrameAsAStateChange() {
    let first = widgetSnapshot()
    let heartbeat = WatchWidgetSnapshot(runtimeID: first.runtimeID, generation: first.generation,
        observedAt: widgetDate.addingTimeInterval(60), sessionID: first.sessionID, activity: .recording,
        capturedDuration: 133, pendingChunkCount: 3, lastSampleAt: widgetDate.addingTimeInterval(60))
    #expect(heartbeat.hasSameCaptureState(as: first))
    let paused = WatchWidgetSnapshot(runtimeID: first.runtimeID, generation: first.generation + 1,
        observedAt: widgetDate, sessionID: first.sessionID, activity: .paused,
        capturedDuration: 73, pendingChunkCount: 3, lastSampleAt: nil)
    #expect(!paused.hasSameCaptureState(as: first))
    #expect(paused.isFresh(at: widgetDate))
    #expect(!paused.isFresh(at: widgetDate.addingTimeInterval(150)))
}
