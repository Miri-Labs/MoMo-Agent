import Foundation
import XCTest
@testable import MoMoAgentClient

final class NotificationTests: XCTestCase {
    func target(_ connection: AgentConnection, extra: [String:Any] = [:]) -> [AnyHashable:Any] {
        var value: [String:Any] = ["v":1,"kind":"final","instance_id":connection.instanceID.uuidString,
            "assistant_id":connection.assistantID.uuidString,"conversation_id":"conversation-" + connection.assistantID.uuidString.lowercased(),
            "run_id":"run-a","message_id":"message-a","delivery_id":UUID().uuidString]
        value.merge(extra) { _, new in new }; return value
    }
    func connection() -> AgentConnection {
        AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: URL(string:"https://example.invalid")!)
    }
    func testColdStartDuplicateTapAndWrongIdentityCannotSubmitOrReopenLater() throws {
        let identity = connection()
        let event = try XCTUnwrap(AgentNotificationTarget.parse(target(identity)))
        var route = AgentNotificationRoute()
        XCTAssertFalse(route.open(event, connection: nil))
        XCTAssertFalse(route.open(event, connection: connection()))
        XCTAssertTrue(route.open(event, connection: identity))
        XCTAssertEqual(route.pending, event, "Keep the target while its Mac is offline")
        XCTAssertFalse(route.open(event, connection: identity))
        route.clear()
        XCTAssertFalse(route.open(event, connection: identity))
        XCTAssertNil(route.pending)
    }
    func testUntrustedPayloadCannotProvideURLCommandOrApproval() throws {
        let identity = connection()
        for extra in [["url":"https://attacker.invalid"],["command":"approve"],["token":"secret"],["kind":"approve"]] {
            XCTAssertNil(AgentNotificationTarget.parse(target(identity, extra: extra)))
        }
        XCTAssertNil(AgentNotificationTarget.parse(target(identity, extra:["kind":"needs_input"])))
        let approval = try XCTUnwrap(AgentNotificationTarget.parse(target(identity, extra:["kind":"needs_input","control_id":"prompt-a","execution_generation":2])))
        XCTAssertFalse(approval.isVisible(messageIDs:["message-a"], controlKeys:["run-a:1:prompt-a"], failedRunIDs:[]))
        XCTAssertTrue(approval.isVisible(messageIDs:[], controlKeys:["run-a:2:prompt-a"], failedRunIDs:[]))
    }
    func testForegroundSuppressionRequiresTheExactRenderedTarget() throws {
        let event = try XCTUnwrap(AgentNotificationTarget.parse(target(connection())))
        XCTAssertFalse(event.isVisible(messageIDs:[], controlKeys:[], failedRunIDs:[]))
        XCTAssertFalse(event.isVisible(messageIDs:["later-message"], controlKeys:[], failedRunIDs:[]))
        XCTAssertTrue(event.isVisible(messageIDs:["message-a"], controlKeys:[], failedRunIDs:[]))
    }
    func testFinalNotificationMustLocateAPersistedMessage() {
        var value = target(connection())
        value.removeValue(forKey: "message_id")
        XCTAssertNil(AgentNotificationTarget.parse(value))
    }
    func testRetryAfterSecondsDatesAndPrivateTransport() async throws {
        XCTAssertEqual(AgentClient.retryDelay("120"), 120)
        XCTAssertNil(AgentClient.retryDelay("not-a-date"))
        XCTAssertEqual(AgentClient.retryDelay("Thu, 01 Jan 1970 00:01:00 GMT", now: Date(timeIntervalSince1970:0)), 60)
        let c = connection()
        let client = try AgentClient(baseURL:c.baseURL, credential:"test", assistantID:c.assistantID, transport: RetryWire())
        do { _ = try await client.conversation(); XCTFail("Expected HTTP 503") }
        catch AgentClientError.http(let status, _, _, let delay) { XCTAssertEqual(status,503); XCTAssertEqual(delay,120) }
    }
}

private struct RetryWire: AgentTransport {
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        AgentByteStream(status:503, contentType:"application/json", retryAfter:"120", chunks: .init { $0.yield(Data("{}".utf8)); $0.finish() })
    }
}
