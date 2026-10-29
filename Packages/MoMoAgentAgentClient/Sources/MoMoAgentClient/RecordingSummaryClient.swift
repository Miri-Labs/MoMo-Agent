import Foundation

public struct RemoteSummaryReceipt: Codable, Sendable, Equatable {
    public let id: String
    public let revision: String
    public let state: String
    public let text: String?
    public let error: String?
}

extension AgentClient {
    /// Queue on the paired Mac. A repeated source revision returns the same durable job.
    public func summarizeRecording(libraryID: UUID, windowID: String, revision: String, text: String) async throws -> RemoteSummaryReceipt {
        struct Input: Encodable { let library_id: String; let window_id: String; let revision: String; let text: String }
        let body = try JSONEncoder().encode(Input(library_id: libraryID.uuidString.lowercased(), window_id: windowID, revision: revision, text: text))
        return try JSONDecoder().decode(RemoteSummaryReceipt.self, from: await request(path: ["v1", "summaries"], method: "POST", body: body))
    }

    public func recordingSummary(id: String) async throws -> RemoteSummaryReceipt {
        try JSONDecoder().decode(RemoteSummaryReceipt.self, from: await request(path: ["v1", "summaries"], query: [.init(name: "id", value: id)]))
    }
}
