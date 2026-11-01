import Foundation

/// Stable execution identity. The API credential is stored separately by the host app.
public struct AgentConnection: Codable, Sendable, Equatable {
    public let workspaceID: UUID
    public let assistantID: UUID
    public let instanceID: UUID
    public let baseURL: URL
    public let dataURL: URL?
    public let network: String?
    public let relayCode: String?

    public init(workspaceID: UUID, assistantID: UUID, instanceID: UUID, baseURL: URL, dataURL: URL? = nil, network: String? = nil, relayCode: String? = nil) {
        self.workspaceID = workspaceID; self.assistantID = assistantID
        self.instanceID = instanceID; self.baseURL = baseURL; self.dataURL = dataURL
        self.network = network; self.relayCode = relayCode
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", assistantID = "assistant_id"
        case instanceID = "instance_id", baseURL = "base_url", dataURL = "data_url"
        case network
        case relayCode = "relay_code"
    }

    public func hasSameIdentity(as other: AgentConnection) -> Bool {
        workspaceID == other.workspaceID && assistantID == other.assistantID && instanceID == other.instanceID
    }
}
