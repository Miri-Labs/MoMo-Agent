import Darwin
import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// Adopted by custom transport errors whose failure represents a retryable link interruption.
public protocol TransientTransportError: Error {
    var isTransientTransportFailure: Bool { get }
}

public enum AgentTransportFailure {
    private static let transientPOSIXCodes: Set<Int> = [
        Int(ENETDOWN), Int(ENETUNREACH), Int(ENETRESET), Int(ECONNABORTED),
        Int(ECONNRESET), Int(ENOBUFS), Int(ENOTCONN), Int(ETIMEDOUT),
        Int(ECONNREFUSED), Int(EHOSTDOWN), Int(EHOSTUNREACH), Int(EPIPE)
    ]

    public static func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    public static func isSocketOrLinkFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if let transient = error as? any TransientTransportError { return transient.isTransientTransportFailure }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return transientPOSIXCodes.contains(nsError.code) }
        #if canImport(CFNetwork)
        if nsError.domain == (kCFErrorDomainCFNetwork as String) {
            return nsError.code != Int(CFNetworkErrors.cfurlErrorCancelled.rawValue)
        }
        #endif
        return false
    }

    public static func isTransient(_ error: Error) -> Bool {
        if isSocketOrLinkFailure(error) { return true }
        if case AgentClientError.http(let status, _, _, _) = error {
            return status == 408 || status == 429 || ((500...599).contains(status) && status != 501)
        }
        return false
    }
}

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
