import Foundation
import MoMoAgentClient
import MoMoAgentRTC

@main struct RTCProbe {
    struct Fixture: Decodable { let connection: AgentConnection; let credential: String }
    actor Events {
        var sequences: [Int] = []
        func append(_ event: AgentRunEvent) { if let seq = event.seq { sequences.append(seq) } }
    }
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 3 else { throw ProbeError.failed("Usage: momo-rtc-probe PRIVATE_FIXTURE direct|relay|fallback|revoke") }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            let network = try AgentRTCTransport(connection: fixture.connection, credential: fixture.credential)
            let client = try AgentClient(baseURL: fixture.connection.baseURL, credential: fixture.credential,
                                         assistantID: fixture.connection.assistantID, transport: network)
            if args[2] == "fallback" {
                do { try await network.connect(); throw ProbeError.failed("Unexpected RTC connection") }
                catch is AgentRTCError { }
                guard try await client.capabilities().features.runSubmission == true, network.route == .https else {
                    throw ProbeError.failed("HTTPS fallback failed")
                }
                network.suspend()
                print(#"{"route":"https","fallback":true}"#)
                return
            }
            try await network.connect()
            for _ in 0..<30 where network.route == .webrtc { try await Task.sleep(for: .milliseconds(100)) }
            let route = network.route
            if args[2] == "relay", route != .relay { throw ProbeError.failed("No selected relay candidate") }
            if args[2] == "direct", route != .direct { throw ProbeError.failed("No selected direct candidate") }
            async let capabilities = client.capabilities()
            async let status = client.run(id: "r1")
            guard try await capabilities.features.runSubmission == true, try await status.runID == "r1" else {
                throw ProbeError.failed("Concurrent requests failed")
            }
            guard let dataURL = fixture.connection.dataURL else { throw ProbeError.failed("Missing context endpoint") }
            let context = try AgentClient(baseURL: dataURL, credential: fixture.credential,
                                          assistantID: fixture.connection.assistantID, transport: network)
            guard try await context.contextStatus().workspaceId == fixture.connection.workspaceID else { throw ProbeError.failed("Context identity differs") }
            let operation = UUID()
            let run = try await client.submit(input: "transport test", sessionID: "s1", operationID: operation)
            let events = Events()
            try await client.observe(runID: run.runID, after: 4) { await events.append($0) }
            guard await events.sequences == [5, 6] else { throw ProbeError.failed("Event cursor failed") }
            if args[2] == "revoke" {
                _ = try await client.run(id: "revoke")
                for _ in 0..<30 where network.route != .https { try await Task.sleep(for: .milliseconds(100)) }
                guard network.route == .https else { throw ProbeError.failed("Revocation left channel open") }
                do { _ = try await client.capabilities(); throw ProbeError.failed("Revoked grant still works") }
                catch AgentClientError.http(let status, _, _, _) where status == 401 { }
                network.suspend()
                print(#"{"revocation":true}"#)
                return
            }
            let observing = Task { try await client.observe(runID: "live", after: 6) { _ in } }
            try await Task.sleep(for: .milliseconds(500))
            observing.cancel(); _ = try? await observing.value
            network.suspend()
            let resumed = try await client.submit(input: "transport test", sessionID: "s1", operationID: operation)
            guard resumed.runID == run.runID else { throw ProbeError.failed("Operation identity changed") }
            let summary: [String: Any] = ["route": route.rawValue, "concurrent": true, "context": true,
                "event_sequences": [5, 6], "cancel_detaches": true, "https_resume_same_run": true]
            print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: .sortedKeys), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    enum ProbeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case let .failed(message) = self { message } else { nil } }
    }
}
