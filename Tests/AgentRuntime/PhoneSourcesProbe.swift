import Foundation
import MoMoAgentClient

@MainActor private final class Reader: PhoneSourcesReading {
    var onChange: (() -> Void)?
    var reads = 0
    var deny = false
    var access = "enabled"
    var visitsEnabled = false
    func requestBackgroundVisits() { }
    func authorization(_ kind: PhoneSourceKind) -> String { access }
    func authorize(_ kind: PhoneSourceKind) async throws { if deny { throw URLError(.cancelled) } }
    func setVisitsEnabled(_ value: Bool) throws { visitsEnabled = value }
    func read(_ kind: PhoneSourceKind, from: Date, to: Date) async throws -> [PhoneSourceSnapshot.Record] {
        reads += 1
        return [.init(id: "fixture", title: "Synthetic task", sourceName: "Fixture List")]
    }
}

private actor Transport: AgentTransport {
    nonisolated let requiresExclusiveRouting = true
    var lost = true
    var bodies: [Data] = []
    var mismatch = false
    func setLost(_ value: Bool) { lost = value }
    func received() -> [Data] { bodies }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        precondition(request.url?.path == "/context/v1/phone-sources")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let body = request.httpBody!; bodies.append(body)
        if lost { throw URLError(.networkConnectionLost) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(PhoneSourceSnapshot.self, from: body)
        let receipt = try JSONSerialization.data(withJSONObject: ["device_id": value.deviceId, "kind": value.kind.rawValue, "revision": value.revision])
        return AgentByteStream(status: 200, contentType: "application/json", chunks: AsyncThrowingStream { $0.yield(receipt); $0.finish() })
    }
}

@main struct PhoneSourcesProbe {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("momo-sources-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = UUID(), transport = Transport(), reader = Reader()
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(),
                                         baseURL: URL(string: "http://127.0.0.1:8765")!, dataURL: URL(string: "http://127.0.0.1:8765/context")!)
        func make() throws -> PhoneSourcesSync {
            try PhoneSourcesSync(directory: directory, deviceID: device, connection: connection, key: "fixture", transport: transport, reader: reader)
        }
        let first = try make()
        await first.refreshAll(); precondition(reader.reads == 0, "No consent means no read/upload")
        reader.deny = true; await first.enable(.calendar); precondition(!first.preference(.calendar).enabled)
        reader.deny = false; await first.enable(.calendar)
        precondition(first.preference(.calendar).enabled && first.failures[.calendar] != nil)
        let original = await transport.received()[0]
        let restored = try make(); await transport.setLost(false); await restored.refresh(.calendar)
        let replay = await transport.received()[1]
        let a = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        let b = try JSONSerialization.jsonObject(with: replay) as! NSDictionary
        precondition(a == b, "Lost ACK replay changed the durable snapshot")
        precondition(restored.preference(.calendar).lastSynced != nil)
        await transport.setLost(true); await restored.refresh(.calendar)
        reader.access = "needs_permission"
        let beforeRevocation = await transport.received().count
        await transport.setLost(false); await restored.refresh(.calendar)
        let revoked = await transport.received().dropFirst(beforeRevocation)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        for body in revoked {
            let snapshot = try decoder.decode(PhoneSourceSnapshot.self, from: body)
            precondition(snapshot.records.isEmpty && snapshot.state == "needs_permission", "Revoked data was replayed")
        }
        reader.access = "enabled"
        await restored.enable(.visits); precondition(reader.visitsEnabled)
        await transport.setLost(true); await restored.disable(.visits)
        precondition(!reader.visitsEnabled && restored.preference(.visits).pending?.state == "disabled")
        await restored.disable(.calendar)
        let deleted = try make(), reads = reader.reads
        await transport.setLost(false); await deleted.refreshAll()
        precondition(reader.reads == reads && deleted.preference(.calendar).pending == nil && deleted.preference(.visits).pending == nil)
        precondition(!deleted.preference(.reminders).enabled, "Source consent must remain independent")
        print("PASS: default opt-out, denied authorization, lost-ACK replay, permission revocation, durable offline deletion, visit monitoring stop, independent source consent (synthetic reader/network)")
    }
}
