import Foundation
import XCTest
@testable import MoMoAgentClient

final class StreamingSubmissionTests: XCTestCase, @unchecked Sendable {
    func testInvalidReceiptClosesTheUnownedStream() async throws {
        let wire = MessageFeedWire(invalidReceipt: true)
        let client = try AgentClient(baseURL: URL(string: "https://fixture.invalid")!, credential: "fixture", assistantID: UUID(), transport: wire)
        do {
            _ = try await client.submitMessageFeed(input: "hello", operationID: UUID(), targetRunID: nil, generation: nil, workID: nil)
            XCTFail("Expected receipt validation")
        } catch AgentClientError.invalidResponse { }
        for _ in 0..<100 where !(await wire.detached) { try await Task.sleep(for: .milliseconds(1)) }
        let detached = await wire.detached
        XCTAssertTrue(detached)
        await wire.finish()
    }
    func testReceiptReturnsBeforeCompletionAndKeepsCoalescedFirstToken() async throws {
        let wire = MessageFeedWire()
        let client = try AgentClient(baseURL: URL(string: "https://fixture.invalid")!, credential: "fixture", assistantID: UUID(), transport: wire)
        let id = UUID()
        let feed = try await client.submitMessageFeed(input: "hello", operationID: id, targetRunID: nil, generation: nil, workID: nil)
        XCTAssertEqual(feed.receipt.runID, "run")
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(requests.first?.networkServiceType, .responsiveData)
        let body = try XCTUnwrap(requests.first?.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["operation_id"] as? String, id.uuidString.lowercased())
        await wire.finish()
        var received: [AgentRunEvent] = []
        for try await event in feed.events { received.append(event) }
        XCTAssertEqual(received.map(\.event), ["message.delta", "run.completed"])
        XCTAssertEqual(received.first?.delta, "你好")
    }

    func testLostReceiptKeepsTheOriginalOperationOnExplicitRetry() async throws {
        let wire = MessageFeedWire(dropReceipt: true)
        let client = try AgentClient(baseURL: URL(string: "https://fixture.invalid")!, credential: "fixture", assistantID: UUID(), transport: wire)
        let id = UUID()
        do {
            _ = try await client.submitMessageFeed(input: "once", operationID: id, targetRunID: nil, generation: nil, workID: nil)
            XCTFail("Expected an ambiguous disconnect")
        } catch URLError.networkConnectionLost { }
        let feed = try await client.submitMessageFeed(input: "once", operationID: id, targetRunID: nil, generation: nil, workID: nil)
        let requests = await wire.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
        await wire.finish()
        for try await _ in feed.events {}
    }

    func testCancellationDetachesTheStreamWithoutStoppingTheRun() async throws {
        let wire = MessageFeedWire()
        let client = try AgentClient(baseURL: URL(string: "https://fixture.invalid")!, credential: "fixture", assistantID: UUID(), transport: wire)
        let feed = try await client.submitMessageFeed(input: "continue", operationID: UUID(), targetRunID: nil, generation: nil, workID: nil)
        let reader = Task { for try await _ in feed.events {} }
        reader.cancel()
        _ = try? await reader.value
        for _ in 0..<100 where !(await wire.detached) { try await Task.sleep(for: .milliseconds(1)) }
        let detached = await wire.detached, requests = await wire.requests
        XCTAssertTrue(detached)
        XCTAssertEqual(requests.count, 1)
    }
}

private actor MessageFeedWire: AgentTransport {
    var requests: [URLRequest] = []
    var dropReceipt: Bool
    let invalidReceipt: Bool
    var detached = false
    var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    init(dropReceipt: Bool = false, invalidReceipt: Bool = false) { self.dropReceipt = dropReceipt; self.invalidReceipt = invalidReceipt }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        requests.append(request)
        if dropReceipt { dropReceipt = false; throw URLError(.networkConnectionLost) }
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { _ in Task { await self.markDetached() } }
        let joined = "data: {\"event\":\"run.accepted\",\"run_id\":\"run\",\"receipt\":{\"run_id\":\"run\",\"status\":\"queued\"}}\n\ndata: {\"event\":\"message.delta\",\"run_id\":\"run\",\"seq\":0,\"delta\":\"你好\"}\n\n"
        continuation.yield(Data((invalidReceipt ? joined.replacingOccurrences(of: "run.accepted", with: "unexpected") : joined).utf8))
        return AgentByteStream(status: 200, contentType: "text/event-stream", chunks: chunks)
    }
    func finish() {
        continuation?.yield(Data("data: {\"event\":\"run.completed\",\"run_id\":\"run\",\"seq\":1}\n\n".utf8))
        continuation?.finish()
    }
    func markDetached() { detached = true }
}
