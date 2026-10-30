import Foundation

enum WebURL {
    static func service(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw WebError.invalidAddress }
        return url
    }
    static func page(_ value: String) throws -> URL {
        guard value.utf8.count <= 8192, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased()), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw WebError.invalidAddress }
        return url
    }
}

private final class NoWebRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a user-supplied API key to a redirected endpoint.
        completionHandler(nil)
    }
}

struct WebHTTP: Sendable {
    var configuration: @Sendable () -> URLSessionConfiguration = { .ephemeral }
    func execute(_ request: URLRequest) async throws -> Data {
        let config = configuration()
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoWebRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw WebError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                switch response.statusCode {
                case 401: throw WebError.authentication
                case 402: throw WebError.quota
                case 403: throw WebError.permission
                case 408, 504: throw WebError.timeout
                case 429: throw WebError.rateLimited
                default: throw WebError.unavailable
                }
            }
            guard response.mimeType == "application/json" else { throw WebError.invalidResponse }
            let maximum = 2 * 1024 * 1024
            guard response.expectedContentLength <= maximum else { throw WebError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximum else { throw WebError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch { throw WebError.sanitized(error) }
    }
}
