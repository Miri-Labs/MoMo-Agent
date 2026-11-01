import Foundation
import CryptoKit
import XCTest
@testable import MoMoAgentClient

final class RelayTests: XCTestCase {
    let code = Data(repeating: 7, count: 32).relayBase64URL

    func testNoPublicHTTPOrMalformedOriginOrSecret() throws {
        for origin in ["http://relay.example", "http://127.0.0.1:8787", "https://u:p@relay.example", "https://relay.example/c/token", "https://relay.example?code=secret"] {
            XCTAssertThrowsError(try RelayTransport(endpoint: URL(string: origin)!, code: code))
        }
        XCTAssertThrowsError(try RelayTransport(endpoint: URL(string: "https://relay.example")!, code: "short"))
        XCTAssertTrue(try RelayTransport(endpoint: URL(string: "https://relay.example")!, code: code).requiresExclusiveRouting)
    }

    func testRelayQRBindsCodeAndRequiresExclusiveTransport() async throws {
        let instance = UUID()
        var body: [String: Any] = ["version": 1, "application": "MoMoAgent", "invitation_id": UUID().uuidString,
            "instance_id": instance.uuidString, "endpoint": "https://relay.example", "network": "relay", "relay_code": code,
            "expires": Date().timeIntervalSince1970 + 120]
        func invitation() throws -> PairingInvitation {
            try PairingInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        }
        let invite = try invitation()
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: instance,
            baseURL: invite.endpoint, network: "relay", relayCode: code)
        XCTAssertTrue(invite.canReuseCredential(from: connection))
        body["relay_code"] = Data(repeating: 8, count: 32).relayBase64URL
        XCTAssertFalse(try invitation().canReuseCredential(from: connection))
        body.removeValue(forKey: "relay_code")
        XCTAssertThrowsError(try invitation())
        do { _ = try await PairingClient(invitation: invite).request(name: "Fixture"); XCTFail("No plaintext fallback") }
        catch { XCTAssertTrue(error is PairingError) }
    }

    func testRequestLimitAndCrossOriginFailBeforeSending() async throws {
        let route = try RelayTransport(endpoint: URL(string: "https://relay.invalid")!, code: code)
        var request = URLRequest(url: URL(string: "https://other.invalid/v1/runs")!)
        do { _ = try await route.open(request); XCTFail() }
        catch { XCTAssertEqual(error as? RelayError, .invalidConfiguration) }
        request.url = URL(string: "https://relay.invalid/v1/runs")!
        request.httpBody = Data(repeating: 0, count: 512 * 1024 + 1)
        do { _ = try await route.open(request); XCTFail() }
        catch { XCTAssertEqual(error as? RelayError, .requestTooLarge) }
    }

    func testNativeCipherRejectsForgedConfirmationAndReplayedResponse() throws {
        var client = RelayCipher(code: code)
        let hello = client.hello()
        let server = P256.KeyAgreement.PrivateKey()
        let serverNonce = Data(repeating: 9, count: 16)
        let clientPublic = try XCTUnwrap(Data(relayBase64URL: hello.epk!))
        let clientNonce = try XCTUnwrap(Data(relayBase64URL: hello.n!))
        let shared = try server.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: clientPublic))
        let transcript = Data(SHA256.hash(data: Data("relay-e2e/v1".utf8) + clientPublic + server.publicKey.x963Representation + clientNonce + serverNonce))
        func key(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(code.utf8),
                sharedInfo: Data((label + "|").utf8) + transcript, outputByteCount: 32)
        }
        var response = RelayFrame(t: "hi", epk: server.publicKey.x963Representation.relayBase64URL,
                                  n: serverNonce.relayBase64URL, cr: Data(repeating: 0, count: 32).relayBase64URL)
        XCTAssertThrowsError(try client.accept(response))
        response.cr = key("confirm-r").withUnsafeBytes { Data($0).relayBase64URL }
        let confirmation = try client.accept(response)
        XCTAssertEqual(confirmation.ci, key("confirm-i").withUnsafeBytes { Data($0).relayBase64URL })
        let body = try JSONEncoder().encode(RelayFrame(t: "hres", id: "fixture", status: 200))
        let sealed = try AES.GCM.seal(body, using: key("s2c"), nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)))
        let wire = try XCTUnwrap(sealed.combined)
        XCTAssertEqual(try client.open(wire).status, 200)
        XCTAssertThrowsError(try client.open(wire))
    }

    func testNativeClientAgainstUpstreamRelayAndPythonResponder() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOMO_RELAY_FIXTURE"] else {
            throw XCTSkip("Run serve_relay_interop_fixture.py against an upstream checkout")
        }
        struct Fixture: Decodable { let endpoint: URL; let code: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let route = try RelayTransport(endpoint: fixture.endpoint, code: fixture.code, allowInsecureLoopback: true)
        func request(_ path: String) -> URLRequest {
            var value = URLRequest(url: fixture.endpoint.appendingPathComponent(path))
            value.setValue("Bearer fixture-phone", forHTTPHeaderField: "Authorization")
            return value
        }
        func open(_ request: URLRequest) async throws -> AgentByteStream {
            let response = try await route.open(request)
            return try XCTUnwrap(response)
        }
        var post = request("v1/runs"); post.httpMethod = "POST"
        post.httpBody = Data("{\"input\":\"中文往返\"}".utf8)
        post.setValue("original-operation", forHTTPHeaderField: "Idempotency-Key")
        let response = try await open(post)
        XCTAssertEqual(response.status, 201)
        var body = Data()
        for try await chunk in response.chunks { body.append(chunk) }
        XCTAssertEqual(body, post.httpBody)
        var events = request("v1/runs/fixture/events")
        events.setValue("7", forHTTPHeaderField: "Last-Event-ID")
        let stream = try await open(events)
        XCTAssertEqual(stream.contentType, "text/event-stream")
        var chunks = [Data]()
        for try await chunk in stream.chunks { chunks.append(chunk) }
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "SSE must arrive incrementally")
        XCTAssertEqual(String(decoding: chunks.reduce(Data(), +), as: UTF8.self), "id: 8\ndata: first\n\nid: 9\ndata: second\n\n")
        let after = try await open(request("v1/capabilities"))
        XCTAssertEqual(after.status, 200)
        after.cancel()
        var unauthorized = request("v1/capabilities")
        unauthorized.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let denied = try await open(unauthorized)
        XCTAssertEqual(denied.status, 401)
        denied.cancel()
        let identity = try await open(request("pair/identity"))
        var identityData = Data()
        for try await chunk in identity.chunks { identityData.append(chunk) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: identityData) as? [String: Any])
        let requests = try XCTUnwrap(object["requests"] as? [[String: Any]])
        XCTAssertTrue(requests.contains { $0["operation"] as? String == "original-operation" })
        XCTAssertTrue(requests.contains { $0["cursor"] as? String == "7" })
    }
}
