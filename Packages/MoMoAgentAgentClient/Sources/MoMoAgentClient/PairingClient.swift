import Foundation

public struct PairingInvitation: Codable, Sendable {
    public let version: Int
    public let application: String
    public let invitationID: UUID
    public let endpoint: URL
    public let instanceID: UUID
    public let expires: Double
    public let network: String?
    enum CodingKeys: String, CodingKey {
        case version, application, endpoint, expires, network
        case invitationID = "invitation_id", instanceID = "instance_id"
    }
    public func canReuseCredential(from connection: AgentConnection) -> Bool {
        instanceID == connection.instanceID && endpoint == connection.baseURL && network == connection.network
    }
    public static func parse(_ text: String, now: Date = Date()) throws -> Self {
        guard text.utf8.count <= 4096 else { throw PairingError.invalidCode }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        let url = value.endpoint
        guard value.version == 1, value.application == "MoMoAgent",
              value.expires > now.timeIntervalSince1970,
              value.expires <= now.timeIntervalSince1970 + 600,
              url.path.isEmpty || url.path == "/" else { throw PairingError.invalidCode }
        if value.network == "tailscale" {
            guard TailnetEndpoint.isOrigin(url) else { throw PairingError.invalidCode }
        } else {
            guard value.network == nil else { throw PairingError.invalidCode }
            _ = try AgentClient(baseURL: url, credential: "validation", assistantID: value.instanceID)
        }
        return value
    }
}

public struct PairingReceipt: Decodable, Sendable {
    public let id: String
    public let name: String
    public let code: String
    public let state: String
    public let expires: Double
    public let connection: AgentConnection?
}

public struct PairingClient: Sendable {
    public let invitation: PairingInvitation
    public let credential: String
    private let session: URLSession
    private let transport: (any AgentTransport)?
    public init(invitation: PairingInvitation, credential: String? = nil,
                configuration: URLSessionConfiguration = .ephemeral, transport: (any AgentTransport)? = nil) {
        self.invitation = invitation
        self.credential = credential ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        self.transport = transport
    }
    public func request(name: String) async throws -> PairingReceipt {
        try await send(path: "pair/requests", body: ["invitation_id": invitation.invitationID.uuidString.lowercased(), "name": name])
    }
    public func status(id: String) async throws -> PairingReceipt {
        guard UUID(uuidString: id) != nil else { throw PairingError.invalidCode }
        let value = try await send(path: "pair/requests/" + id)
        if let connection = value.connection {
            guard connection.instanceID == invitation.instanceID,
                  connection.baseURL == invitation.endpoint,
                  connection.network == invitation.network,
                  connection.dataURL == invitation.endpoint.appendingPathComponent("context") else { throw PairingError.identityChanged }
        }
        return value
    }
    private func send(path: String, body: [String: String]? = nil) async throws -> PairingReceipt {
        if invitation.network != nil {
            guard invitation.network == "tailscale", TailnetEndpoint.isOrigin(invitation.endpoint),
                  transport?.requiresExclusiveRouting == true else { throw PairingError.invalidCode }
        }
        var request = URLRequest(url: invitation.endpoint.appendingPathComponent(path))
        request.timeoutInterval = 12
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        if let stream = try await transport?.open(request) {
            guard stream.status == 200 else { throw PairingError.unavailable }
            var collected = Data()
            for try await chunk in stream.chunks {
                guard collected.count + chunk.count <= 16384 else { throw PairingError.unavailable }
                collected.append(chunk)
            }
            data = collected
        } else {
            guard invitation.network == nil else { throw PairingError.unavailable }
            let result = try await session.data(for: request)
            guard let http = result.1 as? HTTPURLResponse, http.statusCode == 200, result.0.count <= 16384 else { throw PairingError.unavailable }
            data = result.0
        }
        return try JSONDecoder().decode(PairingReceipt.self, from: data)
    }
}

public enum PairingError: Error, LocalizedError {
    case invalidCode, unavailable, identityChanged
    public var errorDescription: String? {
        switch self {
        case .invalidCode: "这不是有效的 MoMo Agent 配对码，或已过期。请在 Mac 刷新后重新扫描。"
        case .unavailable: "暂时无法联系 Mac，请检查异地入口后重试。"
        case .identityChanged: "连接身份与二维码不一致，已停止配对。"
        }
    }
}
