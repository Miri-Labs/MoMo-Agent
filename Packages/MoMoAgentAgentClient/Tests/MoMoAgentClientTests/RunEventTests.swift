import XCTest
@testable import MoMoAgentClient

final class RunEventTests: XCTestCase {
    private func decode(_ json: String) throws -> AgentRunEvent { try JSONDecoder().decode(AgentRunEvent.self, from: Data(json.utf8)) }
    func testUTF8FramesAndHeartbeatsAcrossArbitraryByteBoundaries() throws {
        var parser = RunEventParser()
        var events: [AgentRunEvent] = []
        let wire = ": open\r\n\r\nid: 0\r\ndata: {\"event\":\"message.delta\",\"run_id\":\"r\",\"seq\":0,\"delta\":\"我先看看。\"}\r\n\r\n"
        for byte in wire.utf8 { if let event = try parser.append(byte) { events.append(event) } }
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.delta, "我先看看。")
    }
    func testInterimReplacesDeltasAndReplayDoesNotDuplicateReply() throws {
        var reply = RemoteReply()
        reply.apply(try decode(#"{"event":"message.delta","run_id":"r","seq":0,"delta":"我先"}"#))
        let interim = try decode(#"{"event":"message.interim","run_id":"r","seq":1,"text":"我先整理方案。","already_streamed":true}"#)
        reply.apply(interim); reply.apply(interim)
        XCTAssertEqual(reply.messages, ["我先整理方案。"]); XCTAssertTrue(reply.partial.isEmpty)
        let saved = try JSONDecoder().decode(RemoteReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(saved, reply); XCTAssertFalse(reply.hasStartedWork)
        reply.apply(try decode(#"{"event":"tool.started","run_id":"r","seq":2,"tool":"read_recording"}"#))
        XCTAssertTrue(reply.hasStartedWork); XCTAssertEqual(reply.sequence, 2)
    }
    func testReasoningIsNotPresentedAndMissingReplayIsExplicit() throws {
        var reply = RemoteReply()
        reply.apply(try decode(#"{"event":"reasoning.available","run_id":"r","seq":0,"text":"private"}"#))
        XCTAssertFalse(reply.hasText)
        reply.apply(try decode(#"{"event":"replay.truncated","run_id":"r"}"#))
        XCTAssertTrue(reply.historyIncomplete)
    }
    func testToolLifecycleSeparatesTypingFromExecutionAndReplaysOnce() throws {
        var reply = RemoteReply()
        reply.apply(try decode(#"{"event":"tool.started","run_id":"r","seq":0,"tool":"read_recording"}"#))
        XCTAssertEqual(reply.phase, "working")
        let done = try decode(#"{"event":"tool.completed","run_id":"r","seq":1,"tool":"read_recording"}"#)
        reply.apply(done); reply.apply(done)
        XCTAssertEqual(reply.tools?.count, 1); XCTAssertEqual(reply.tools?.first?.state, "succeeded")
        XCTAssertEqual(reply.phase, "waiting")
        reply.apply(try decode(#"{"event":"message.delta","run_id":"r","seq":2,"delta":"整理好了"}"#))
        XCTAssertEqual(reply.phase, "writing")
        let restored = try JSONDecoder().decode(RemoteReply.self, from: JSONEncoder().encode(reply))
        XCTAssertEqual(restored, reply)
        let legacy = try JSONDecoder().decode(RemoteReply.self, from: Data(#"{"messages":[],"partial":"","hasStartedWork":false,"historyIncomplete":false,"streamUnavailable":false}"#.utf8))
        XCTAssertNil(legacy.phase); XCTAssertNil(legacy.tools)
    }
    func testTypingStartsInLocalOutboxAndStopsOnDisconnectOrStop() throws {
        var value: [String: Any] = ["id": UUID().uuidString, "sessionID": "session", "input": "hello", "createdAt": 0,
                                    "needsReview": false, "stopRequested": false]
        func waiting() throws -> Bool { try JSONDecoder().decode(RemoteTask.self, from: JSONSerialization.data(withJSONObject: value)).isAwaitingReply }
        XCTAssertTrue(try waiting(), "Show waiting immediately, before any network acknowledgement")
        value["run"] = ["run_id": "r", "session_id": "session", "status": "queued"]
        XCTAssertTrue(try waiting())
        value["run"] = ["run_id": "r", "session_id": "session", "status": "running"]
        XCTAssertTrue(try waiting())
        value["lastError"] = "offline"; XCTAssertFalse(try waiting()); value.removeValue(forKey: "lastError")
        value["stopRequested"] = true; XCTAssertFalse(try waiting()); value["stopRequested"] = false
        value["reply"] = ["messages": [], "partial": "", "hasStartedWork": false, "historyIncomplete": false, "streamUnavailable": true]
        XCTAssertTrue(try waiting(), "A server without SSE still delivers replies through the conversation cursor")
        value["reply"] = ["messages": [], "partial": "首字", "hasStartedWork": false, "historyIncomplete": false, "streamUnavailable": false, "phase": "writing"]
        XCTAssertTrue(try waiting(), "Partial text stays buffered until a complete message arrives")
        value["reply"] = ["messages": ["完整回复"], "partial": "", "hasStartedWork": true, "historyIncomplete": false, "streamUnavailable": false, "phase": "waiting"]
        XCTAssertFalse(try waiting(), "A completed tool must not flash typing below an existing reply")
        value["reply"] = ["messages": [], "partial": "", "hasStartedWork": false, "historyIncomplete": false, "streamUnavailable": false, "phase": "finished"]
        XCTAssertTrue(try waiting(), "An event without a visible reply must not leave an empty gap")
        value["run"] = ["run_id": "r", "session_id": "session", "status": "failed"]
        XCTAssertFalse(try waiting(), "Authoritative failure ends waiting")
    }
    func testParallelToolIDsAndBooleanFailureArePreserved() throws {
        var reply = RemoteReply()
        reply.apply(try decode(#"{"event":"tool.started","run_id":"r","seq":0,"tool":"read","tool_call_id":"a"}"#))
        reply.apply(try decode(#"{"event":"tool.started","run_id":"r","seq":1,"tool":"read","tool_call_id":"b"}"#))
        reply.apply(try decode(#"{"event":"tool.completed","run_id":"r","seq":2,"tool":"read","tool_call_id":"a","error":true}"#))
        XCTAssertEqual(reply.tools?.first?.state, "failed"); XCTAssertEqual(reply.tools?.last?.state, "running")
        XCTAssertEqual(reply.phase, "working")
        reply.apply(try decode(#"{"event":"run.failed","run_id":"r","seq":3,"error":"failure detail"}"#))
        XCTAssertEqual(reply.phase, "finished")
    }
    func testUnterminatedOversizedFrameFailsInsteadOfGrowingForever() throws {
        var parser = RunEventParser()
        for _ in 0..<(512 * 1024) { _ = try parser.append(65) }
        XCTAssertThrowsError(try parser.append(65))
    }
}
