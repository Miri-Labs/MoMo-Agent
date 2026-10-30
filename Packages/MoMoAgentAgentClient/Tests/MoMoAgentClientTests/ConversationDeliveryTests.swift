import Foundation
import XCTest
@testable import MoMoAgentClient

@MainActor
final class ConversationDeliveryTests: XCTestCase {
    private func store(_ wire: ConversationWire) async throws -> (RemoteTaskStore, URL, AgentClient, AgentConnection) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(),
            baseURL: URL(string: "https://conversation.invalid")!)
        await wire.configure(connection)
        let client = try AgentClient(baseURL: connection.baseURL, credential: "fixture", assistantID: connection.assistantID, transport: wire)
        let file = folder.appendingPathComponent("journal.json")
        return (try RemoteTaskStore(file: file, connection: connection, client: client), file, client, connection)
    }

    func testSendingInformationDoesNotWaitForAnExistingStatusRequest() async throws {
        let wire = ConversationWire(holdFirstPoll: true)
        let (store, _, _, _) = try await store(wire)
        store.setDraft("处理一个耗时任务"); try store.enqueue()
        let firstRefresh = Task { await store.refresh() }
        for _ in 0..<100 {
            if await wire.pollIsHeld { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await wire.pollIsHeld
        XCTAssertTrue(held)
        store.setDraft("我周五去上海")
        let information = try store.enqueue()
        await store.refresh()
        XCTAssertNotNil(store.tasks.first(where: { $0.id == information })?.run)
        let inputs = await wire.inputs
        XCTAssertEqual(inputs, ["处理一个耗时任务", "我周五去上海"])
        await wire.releasePoll()
        await firstRefresh.value
        XCTAssertEqual(store.tasks.count, 2)
        let controls = await wire.controlRequests
        XCTAssertEqual(controls, 0, "New information is a normal message, never an implicit stop or steer")
    }

    func testLegacyDeliveryNeverStartsAHiddenClientTurn() async throws {
        let wire = ConversationWire()
        let (store, file, client, connection) = try await store(wire)
        store.setDraft("后台整理资料"); try store.enqueue(); await store.refresh()
        await wire.finishBackgroundWork(); await store.refresh()
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.refresh(); await reopened.refresh()
        XCTAssertEqual(reopened.tasks.count, 1)
        XCTAssertTrue(reopened.tasks.allSatisfy { $0.backgroundMessageIDs == nil })
        let inputs = await wire.inputs
        XCTAssertEqual(inputs.count, 1, "Only the Mac owns completion turns")
    }

    func testHumanContinuationAlreadyContainingTheResultDoesNotGetAnotherWake() async throws {
        let wire = ConversationWire()
        let (store, _, _, _) = try await store(wire)
        store.setDraft("后台整理资料"); try store.enqueue(); await store.refresh()
        await wire.finishBackgroundWork()
        store.setDraft("我周五去上海"); try store.enqueue(); await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.tasks.count, 2, "The native human turn already loaded the delivery from session history")
    }


}

private actor ConversationWire: AgentTransport {
    private var connection: AgentConnection?
    func configure(_ value: AgentConnection) { connection = value }
    private var requests: [URLRequest] = []
    private var submitted: [(String, String, String)] = []
    private var firstPoll: CheckedContinuation<Void, Never>?
    private var holdFirstPoll: Bool
    private var backgroundFinished = false
    private var humanAfterCompletion = false
    private var loseWakeReceipt: Bool
    private var operations: [String: String] = [:]
    var pollIsHeld: Bool { firstPoll != nil }
    var inputs: [String] { submitted.map(\.1) }
    var controlRequests: Int { requests.filter { $0.url!.path.hasSuffix("/stop") || $0.url!.path.hasSuffix("/steer") }.count }

    var wakeOperationKeys: [String] { requests.filter { $0.httpMethod == "POST" &&
        String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("后台委派") }.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") } }

    init(holdFirstPoll: Bool = false, loseWakeReceipt: Bool = false) {
        self.holdFirstPoll = holdFirstPoll; self.loseWakeReceipt = loseWakeReceipt
    }
    func releasePoll() { firstPoll?.resume(); firstPoll = nil; holdFirstPoll = false }
    func finishBackgroundWork() { backgroundFinished = true }

    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        requests.append(request)
        let path = request.url!.path
        let response: [String: Any]
        if path == "/momo/v1/conversation" {
            let c = connection!
            response = ["conversation_id": "fixture", "session_id": "momo-main-" + c.assistantID.uuidString.lowercased(),
                "assistant_id": c.assistantID.uuidString, "instance_id": c.instanceID.uuidString,
                "capabilities": ["shared_conversation": true, "server_owned_completion": true, "durable_steering": true, "independent_chat_while_waiting": false, "system_push": false]]
        } else if path == "/momo/v1/conversation/runs" { response = ["data": []]
        } else if path == "/momo/v1/conversation/messages", request.httpMethod == "GET" { response = ["data": [], "next_cursor": 0, "has_more": false]
        } else if path.hasSuffix("/capabilities") {
            response = ["features": ["run_submission": true, "session_resources": true,
                "runs_idempotency": ["supported": true, "durable": true, "retention_seconds": 86400]]]
        } else if request.httpMethod == "POST", path == "/momo/v1/conversation/messages" {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            if backgroundFinished, body["content"] == "我周五去上海" { humanAfterCompletion = true }
            let key = body["operation_id"]!
            let id = operations[key] ?? "run-\(submitted.count)"
            if operations[key] == nil {
                submitted.append((id, body["content"]!, "momo-main-" + connection!.assistantID.uuidString.lowercased())); operations[key] = id
            }
            if loseWakeReceipt, body["content"]!.hasPrefix("后台委派") {
                loseWakeReceipt = false; throw URLError(.timedOut)
            }
            response = ["run_id": id, "status": "started"]
        } else if path.contains("/api/sessions/") {
            var rows: [[String: Any]] = [["id": 1, "role": "user"], ["id": 2, "role": "assistant"]]
            if backgroundFinished { rows.append(["id": 900, "role": "user", "display_kind": "async_delegation_complete"]) }
            if humanAfterCompletion { rows.append(["id": 1000, "role": "user"]) }
            response = ["data": rows]
        } else if let item = submitted.first(where: { path.hasSuffix("/" + $0.0) }) {
            if item.0 == "run-0", holdFirstPoll {
                await withCheckedContinuation { firstPoll = $0 }
            }
            response = ["run_id": item.0, "session_id": item.2, "status": "completed",
                "output": item.1.hasPrefix("后台委派") ? "整理完成，这是实际结果" : "收到这条信息"]
        } else { throw AgentClientError.invalidInput }
        let data = try JSONSerialization.data(withJSONObject: response)
        return AgentByteStream(status: 200, contentType: "application/json", chunks: .init { continuation in
            continuation.yield(data); continuation.finish()
        })
    }
}
