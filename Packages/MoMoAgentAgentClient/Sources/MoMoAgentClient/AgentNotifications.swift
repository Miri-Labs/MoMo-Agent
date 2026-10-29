import Foundation

public struct AgentPushStatus: Decodable, Sendable, Equatable {
    public let configured: Bool
    public let registered: Bool
    public let enabled: Bool
    public let topic: String
    public let environment: String?
}

/// Only opaque identities can cross the notification boundary. No URL, command or credential.
public struct AgentNotificationTarget: Codable, Sendable, Equatable {
    public let kind: String
    public let instanceID: UUID
    public let assistantID: UUID
    public let conversationID: String
    public let deliveryID: UUID
    public let messageID: String?
    public let runID: String
    public let controlID: String?
    public let executionGeneration: Int?
    enum CodingKeys: String, CodingKey {
        case kind, instanceID = "instance_id", assistantID = "assistant_id", conversationID = "conversation_id"
        case deliveryID = "delivery_id", messageID = "message_id", runID = "run_id", controlID = "control_id", executionGeneration = "execution_generation"
    }
    public static func parse(_ value: [AnyHashable: Any]) -> Self? {
        let keys = Set(value.keys.compactMap { $0 as? String })
        let allowed: Set<String> = ["v","kind","instance_id","assistant_id","conversation_id","delivery_id","message_id","run_id","control_id","execution_generation"]
        guard keys.isSubset(of: allowed), value["v"] as? Int == 1,
              let data = try? JSONSerialization.data(withJSONObject: value),
              let target = try? JSONDecoder().decode(Self.self, from: data),
              ["final","failed","needs_input"].contains(target.kind),
              [target.conversationID, target.runID, target.messageID, target.controlID].compactMap({ $0 }).allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 200 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
              }), target.kind != "final" || target.messageID != nil,
              target.kind != "needs_input" || (target.controlID != nil && (target.executionGeneration ?? 0) > 0) else { return nil }
        return target
    }
    public func matches(_ connection: AgentConnection) -> Bool {
        instanceID == connection.instanceID && assistantID == connection.assistantID &&
        conversationID == "conversation-" + connection.assistantID.uuidString.lowercased()
    }
    public func isVisible(messageIDs: Set<String>, controlKeys: Set<String>, failedRunIDs: Set<String>) -> Bool {
        if kind == "needs_input" { return controlKeys.contains(controlKey ?? "") }
        if kind == "failed" { return failedRunIDs.contains(runID) }
        return messageID.map { messageIDs.contains($0) } ?? false
    }
    public var controlKey: String? {
        guard let controlID, let executionGeneration else { return nil }
        return "\(runID):\(executionGeneration):\(controlID)"
    }
}

/// A tap is a navigation intent; it never submits Agent input or an approval.
public struct AgentNotificationRoute: Sendable {
    public private(set) var pending: AgentNotificationTarget?
    private var handled: [UUID] = []
    public init() {}
    @discardableResult public mutating func open(_ target: AgentNotificationTarget, connection: AgentConnection?) -> Bool {
        guard let connection, target.matches(connection), !handled.contains(target.deliveryID) else { return false }
        handled.append(target.deliveryID); if handled.count > 128 { handled.removeFirst() }
        pending = target
        return true
    }
    public mutating func clear() { pending = nil }
}

extension AgentClient {
    public func pushStatus() async throws -> AgentPushStatus {
        try JSONDecoder().decode(AgentPushStatus.self, from: await request(path: ["momo","v1","conversation","push"]))
    }
    public func registerPush(token: String, registrationID: UUID, topic: String, environment: String) async throws -> AgentPushStatus {
        let body = try JSONSerialization.data(withJSONObject: ["token":token,"registration_id":registrationID.uuidString.lowercased(),"topic":topic,"environment":environment])
        return try JSONDecoder().decode(AgentPushStatus.self, from: await request(path: ["momo","v1","conversation","push"], method: "POST", body: body))
    }
    public func revokePush() async throws {
        _ = try await request(path: ["momo","v1","conversation","push","revoke"], method: "POST", body: Data("{}".utf8))
    }
    public func markFailedRunsVisible(_ runIDs: Set<String>) async throws {
        let body = try JSONSerialization.data(withJSONObject: runIDs.map { ["kind":"failed","run_id":$0] })
        _ = try await request(path: ["momo","v1","conversation","push","visible"], method: "POST", body: body)
    }
    public func markControlsVisible(_ values: [(run: AgentRun, control: AgentControl)]) async throws {
        let body = try JSONSerialization.data(withJSONObject: values.compactMap { run, control -> [String:Any]? in
            guard let generation = run.executionGeneration else { return nil }
            return ["run_id":run.runID,"control_id":control.promptID,"execution_generation":generation]
        })
        _ = try await request(path: ["momo","v1","conversation","push","visible"], method: "POST", body: body)
    }
}
