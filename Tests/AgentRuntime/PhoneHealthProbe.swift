import Foundation
import MoMoAgentClient

@MainActor
private final class Reader: PhoneHealthReading {
    var available = true
    var reads = 0
    var deny = false
    var unavailable = false
    func authorize() async throws { if deny { throw URLError(.cancelled) } }
    func read(now: Date, start: Date, calendar: Calendar) async throws -> [HealthSnapshot.Observation] {
        reads += 1
        if unavailable { throw URLError(.dataNotAllowed) }
        return [.init(metric: "heart_rate", unit: "count/min", value: 63, start: now.addingTimeInterval(-10), end: now,
                      sourceName: "Synthetic Watch", sourceBundle: "fixture.health")]
    }
}

private actor Transport: AgentTransport {
    nonisolated let requiresExclusiveRouting = true
    var lost = true
    var bodies: [Data] = []
    func setLost(_ value: Bool) { lost = value }
    func received() -> [Data] { bodies }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        precondition(request.url?.path == "/context/v1/health")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let body = request.httpBody!; bodies.append(body)
        if lost { throw URLError(.networkConnectionLost) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(HealthSnapshot.self, from: body)
        let receipt = try JSONSerialization.data(withJSONObject: ["device_id": value.deviceId, "revision": value.revision])
        return AgentByteStream(status: 200, contentType: "application/json", chunks: AsyncThrowingStream { $0.yield(receipt); $0.finish() })
    }
}

@main struct PhoneHealthProbe {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("momo-health-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = UUID(), transport = Transport(), reader = Reader()
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(),
                                         baseURL: URL(string: "http://127.0.0.1:8765")!, dataURL: URL(string: "http://127.0.0.1:8765/context")!)
        func make() throws -> PhoneHealthSync {
            try PhoneHealthSync(directory: directory, deviceID: device, connection: connection, key: "fixture", transport: transport, reader: reader)
        }
        let first = try make()
        await first.refresh(); precondition(reader.reads == 0, "No consent means no read/upload")
        reader.deny = true; await first.enable(); precondition(!first.enabled)
        reader.deny = false; await first.enable()
        precondition(first.enabled && first.failure != nil && first.lastSynced == nil)
        let original = await transport.received()[0]
        let restored = try make(); await transport.setLost(false); await restored.refresh()
        let replay = await transport.received()[1]
        let originalValue = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        let replayValue = try JSONSerialization.jsonObject(with: replay) as! NSDictionary
        precondition(originalValue == replayValue)
        precondition(restored.lastSynced != nil && restored.hasReadableData)
        reader.unavailable = true; await restored.refresh()
        precondition(!restored.hasReadableData && restored.failure != nil, "Read failures withdraw stale evidence")
        await transport.setLost(true); await restored.disable()
        precondition(!restored.enabled && restored.deletionPending)
        let deleted = try make(); let reads = reader.reads
        await transport.setLost(false); await deleted.refresh()
        precondition(!deleted.deletionPending && !deleted.enabled && reader.reads == reads)
        let last = await transport.received().last!
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(HealthSnapshot.self, from: last)
        precondition(snapshot.state == "disabled" && snapshot.observations.isEmpty)
        print("PASS: consent, lost-ACK replay after restart, unavailable-read withdrawal, durable opt-out and no post-opt-out reads (synthetic HealthKit/network)")
    }
}
