import Foundation
import XCTest
@testable import MoMoAgentClient

final class AgentMessageReceiptTests: XCTestCase {
    private func run(_ status: String, generation: Int? = nil, delivery: String? = nil) -> AgentRun {
        var value = AgentRun(runID: "run", sessionID: "session", status: status, output: nil, error: nil)
        value.executionGeneration = generation; value.deliveryState = delivery
        return value
    }

    func testUnsentAcceptedClaimedAndRestoredExecution() throws {
        XCTAssertNil(AgentMessageReceipt.resolve(runs: []))
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [], serverConfirmed: true), .delivered)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("queued")]), .delivered)
        let claimed = run("running", generation: 3)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [claimed]), .read)
        // An older acknowledgement cannot downgrade a newer execution event.
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [claimed, run("queued")]), .read)
        let restored = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run("failed", generation: 3)))
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [restored]), .read)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("cancelled")]), .delivered)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("unknown")]), .delivered)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("unknown", generation: 3)]), .read)
    }

    func testSteeringIsReadOnlyAfterConsumption() {
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("running", generation: 3, delivery: "steering")]), .delivered)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("completed", generation: 3, delivery: "applied")]), .read)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [run("running", generation: 3)], messageState: "pending"), .delivered)
        XCTAssertEqual(AgentMessageReceipt.resolve(runs: [], messageState: "applied", serverConfirmed: true), .read)
        XCTAssertNil(AgentMessageReceipt.resolve(runs: [run("not_applied", generation: 3)]))
        XCTAssertNil(AgentMessageReceipt.resolve(runs: [run("completed", generation: 3)], messageState: "not_applied", serverConfirmed: true))
    }
}
