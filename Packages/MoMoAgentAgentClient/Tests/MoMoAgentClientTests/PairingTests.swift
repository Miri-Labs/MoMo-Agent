import Foundation
import XCTest
@testable import MoMoAgentClient

final class PairingTests: XCTestCase {
    func testRescanMayReuseSecretOnlyForThePreviouslyTrustedOriginAndIdentity() throws {
        let instance = UUID()
        let connection = try JSONDecoder().decode(AgentConnection.self, from: JSONSerialization.data(withJSONObject: [
            "workspace_id": UUID().uuidString, "assistant_id": UUID().uuidString, "instance_id": instance.uuidString,
            "base_url": "http://100.64.0.1:8767", "data_url": "http://100.64.0.1:8767/context", "network": "tailscale"]))
        var body: [String: Any] = ["version": 1, "application": "MoMoAgent", "invitation_id": UUID().uuidString,
            "instance_id": instance.uuidString, "endpoint": "http://100.64.0.1:8767", "network": "tailscale",
            "expires": Date().timeIntervalSince1970 + 120]
        func invitation() throws -> PairingInvitation {
            try PairingInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        }
        XCTAssertTrue(try invitation().canReuseCredential(from: connection))
        body["invitation_id"] = UUID().uuidString
        XCTAssertTrue(try invitation().canReuseCredential(from: connection), "Refreshing the QR does not change the phone")
        body["endpoint"] = "http://100.64.0.2:8767"
        XCTAssertFalse(try invitation().canReuseCredential(from: connection), "A QR must not exfiltrate an existing grant")
        body["endpoint"] = "http://100.64.0.1:8767"; body["instance_id"] = UUID().uuidString
        XCTAssertFalse(try invitation().canReuseCredential(from: connection))
    }
    func testEmbeddedNetworkIsExplicitAndCannotSelectAnArbitraryProxyDestination() throws {
        var body: [String: Any] = ["version":1,"application":"MoMoAgent","invitation_id":UUID().uuidString,
            "instance_id":UUID().uuidString,"endpoint":"http://100.64.0.1:8767","expires":Date().timeIntervalSince1970 + 120,
            "network":"tailscale"]
        func parse() throws -> PairingInvitation { try PairingInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self)) }
        XCTAssertEqual(try parse().network, "tailscale")
        for host in ["https://example.com", "http://mac.tail123.ts.net", "https://mac.tail123.ts.net.evil.example",
                     "http://127.0.0.1:8767", "http://100.128.0.1:8767", "http://100.63.255.255:8767",
                     "http://100.64.0.1:80", "http://100.64.0.1:8767/path", "http://100.64.0.1:8767?key=secret",
                     "http://user@100.64.0.1:8767", "http://[fd7a:115c:a1e0::1]:8767", "http://example.com:8767"] {
            body["endpoint"] = host; XCTAssertThrowsError(try parse())
        }
        body["endpoint"] = "http://100.64.0.1:8767"; body["network"] = "unknown"
        XCTAssertThrowsError(try parse())
        body.removeValue(forKey: "network")
        XCTAssertThrowsError(try parse(), "Private HTTP without the network marker must be rejected")
        body["endpoint"] = "https://relay.example"
        XCTAssertNil(try parse().network)
    }
    func testEmbeddedPairingCannotFallBackWithoutTransport() async throws {
        let body: [String: Any] = ["version":1,"application":"MoMoAgent","invitation_id":UUID().uuidString,
            "instance_id":UUID().uuidString,"endpoint":"http://100.64.0.1:8767","expires":Date().timeIntervalSince1970 + 120,
            "network":"tailscale"]
        let invite = try PairingInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        do {
            _ = try await PairingClient(invitation: invite).request(name: "Fixture")
            XCTFail("A private invitation must require its embedded transport")
        } catch { XCTAssertTrue(error is PairingError) }
    }
    func testInvitationValidationAndCredentialStability() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let instance = UUID()
        var body: [String: Any] = ["version":1,"application":"MoMoAgent","invitation_id":UUID().uuidString,"instance_id":instance.uuidString,"endpoint":"https://temporary.example","expires":1300]
        func parse() throws -> PairingInvitation { try PairingInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self), now: now) }
        let invite = try parse(); let first = PairingClient(invitation: invite)
        XCTAssertEqual(64, first.credential.count)
        XCTAssertEqual(first.credential, PairingClient(invitation: invite, credential: first.credential).credential)
        for url in ["http://public.example", "https://user:secret@example.com", "https://example.com/path", "https://example.com/?key=secret"] {
            body["endpoint"] = url; XCTAssertThrowsError(try parse())
        }
        body["endpoint"] = "http://127.0.0.1:18887"; XCTAssertNoThrow(try parse())
        body["expires"] = 999; XCTAssertThrowsError(try parse())
        body["expires"] = 5000; XCTAssertThrowsError(try parse())
    }
    func testChangingNetworkAddressDoesNotChangeMacIdentity() throws {
        let workspace = UUID(), assistant = UUID(), instance = UUID()
        func connection(_ url: String, instanceID: UUID) throws -> AgentConnection {
            try JSONDecoder().decode(AgentConnection.self, from: JSONSerialization.data(withJSONObject: ["workspace_id":workspace.uuidString,"assistant_id":assistant.uuidString,"instance_id":instanceID.uuidString,"base_url":url,"data_url":url+"/context"]))
        }
        let first = try connection("https://first.example", instanceID: instance)
        XCTAssertTrue(first.hasSameIdentity(as: try connection("https://second.example", instanceID: instance)))
        XCTAssertFalse(first.hasSameIdentity(as: try connection("https://second.example", instanceID: UUID())))
    }
}
