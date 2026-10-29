import Foundation
import MoMoAgentClient

let rtcProtocol = "momo-rpc-v1"

struct RTCIdentity: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let assistantID: UUID
    let instanceID: UUID
    init(_ connection: AgentConnection) {
        workspaceID = connection.workspaceID; assistantID = connection.assistantID; instanceID = connection.instanceID
    }
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", assistantID = "assistant_id", instanceID = "instance_id"
    }
}

struct RTCOptions: Decodable {
    struct Server: Decodable {
        let urls: [String]
        let username: String?
        let credential: String?
    }
    let available: Bool
    let identity: RTCIdentity
    let protocolName: String
    let iceServers: [Server]
    let iceTransportPolicy: String
    let maxRequestBytes: Int
    enum CodingKeys: String, CodingKey {
        case available, identity, protocolName = "protocol", iceServers = "ice_servers"
        case iceTransportPolicy = "ice_transport_policy", maxRequestBytes = "max_request_bytes"
    }
}

struct RTCOffer: Encodable {
    let identity: RTCIdentity
    let nonce: String
    let sdp: String
    let type = "offer"
    let protocolName = rtcProtocol
    enum CodingKeys: String, CodingKey { case identity, nonce, sdp, type, protocolName = "protocol" }
}

struct RTCFrame: Decodable, Sendable {
    let kind: String?
    let id: String?
    let status: Int?
    let contentType: String?
    let retryAfter: String?
    let body: String?
    let identity: RTCIdentity?
    let nonce: String?
    let sessionID: String?
    let sdp: String?
    let type: String?
    let protocolName: String?
    enum CodingKeys: String, CodingKey {
        case kind, id, status, body, identity, nonce, sdp, type
        case retryAfter = "retry_after", contentType = "content_type", sessionID = "session_id", protocolName = "protocol"
    }
}

struct RTCRequest: Encodable {
    let kind = "request"
    let id: String
    let method: String
    let path: String
    let headers: [String: String]
    let body: String
}

public enum AgentRTCError: Error, LocalizedError {
    case unavailable, identityChanged, disconnected, timeout, invalidFrame, bufferFull
    public var errorDescription: String? {
        switch self {
        case .unavailable: "WebRTC 暂不可用，继续使用 HTTPS。"
        case .identityChanged: "WebRTC 的 Mac 身份不匹配，已关闭该连接。"
        case .disconnected: "WebRTC 已断开，请按原任务核对结果。"
        case .timeout: "WebRTC 连接超时，继续使用 HTTPS 核对原任务。"
        case .invalidFrame: "WebRTC 响应无效，已关闭该连接。"
        case .bufferFull: "WebRTC 接收缓冲区已满，请恢复原事件游标。"
        }
    }
}
