import Foundation

public struct DesktopVideoSignal: Codable, Sendable {
    public let version: Int
    public let nonce: UUID
    public let sdp: String
    public init(nonce: UUID = UUID(), sdp: String) { version = 1; self.nonce = nonce; self.sdp = sdp }
}
extension AgentClient {
    public func desktopVideoOffer(_ offer: DesktopVideoSignal) async throws -> DesktopVideoSignal {
        let data = try await request(path: ["desktop", "v2", "offer"], method: "POST", body: JSONEncoder().encode(offer))
        let answer = try JSONDecoder().decode(DesktopVideoSignal.self, from: data)
        guard answer.version == 1, answer.nonce == offer.nonce, answer.sdp.utf8.count <= 131072 else { throw AgentClientError.invalidResponse }
        return answer
    }
}
