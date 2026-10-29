import Foundation

/// Returning nil means no request was sent; the caller may use its HTTPS connection.
/// After dispatch, failures propagate to the durable operation owner, never replay a write here.
public protocol AgentTransport: Sendable {
    /// A private route may never send credentials through the default URLSession.
    var requiresExclusiveRouting: Bool { get }
    func open(_ request: URLRequest) async throws -> AgentByteStream?
}

public extension AgentTransport {
    var requiresExclusiveRouting: Bool { false }
}

public struct AgentByteStream: Sendable {
    public let status: Int
    public let contentType: String?
    public let retryAfter: String?
    public let chunks: AsyncThrowingStream<Data, Error>
    private let cancellation: @Sendable () -> Void

    public init(status: Int, contentType: String?, retryAfter: String? = nil, chunks: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.contentType = contentType; self.chunks = chunks; self.retryAfter = retryAfter
        self.cancellation = cancel
    }
    public func cancel() { cancellation() }
}
