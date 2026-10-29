import Foundation

/// Owns configuration, cancellation and a bounded, memory-only page cache independently of chat views.
public actor WebAccess {
    private let store: WebStore
    private let client: WebClient
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    private struct CachedPage {
        let id: UUID
        let requestedURL: URL
        let provider: WebProvider
        let document: WebDocument
        let revision: UUID
        let createdAt: Date
    }
    private var pages: [CachedPage] = []

    public init(root: URL, credentials: any WebCredentialVault) {
        store = .init(root: root, credentials: credentials); client = .init()
    }
    init(root: URL, credentials: any WebCredentialVault, http: WebHTTP) {
        store = .init(root: root, credentials: credentials); client = .init(http: http)
    }
    public func settings() throws -> WebSettings { try store.load() }
    public func save(_ draft: WebConnectionDraft) throws -> WebSettings {
        let value = try store.commit(draft); cancelRequests(); return value
    }
    public func update(enabled: Bool, search: WebProvider?, fetch: WebProvider?, revision: UUID) throws -> WebSettings {
        var value = try store.load()
        guard value.revision == revision else { throw WebError.staleSettings }
        value.enabled = enabled; value.searchProvider = search; value.fetchProvider = fetch; value.revision = UUID()
        try store.save(value); cancelRequests(); return value
    }
    public func remove(_ provider: WebProvider, revision: UUID) throws -> WebSettings {
        let value = try store.remove(provider, revision: revision); cancelRequests(); return value
    }
    public func retryCredentialCleanup() throws -> WebSettings { store.cleanup(try store.load()) }

    public func test(_ draft: WebConnectionDraft) async throws -> WebConnectionTest {
        let value = try store.load(), (base, key) = try store.key(draft, settings: value), client = client
        return try await run(revision: value.revision) {
            let search: Result<Int, WebError>, fetch: Result<Int, WebError>
            do { search = .success(try await client.search(provider: draft.provider, base: base, key: key,
                query: "Swift programming language", count: 1).results.count) }
            catch { try Task.checkCancellation(); search = .failure(WebError.sanitized(error)) }
            do { fetch = .success(try await client.fetch(provider: draft.provider, base: base, key: key,
                url: URL(string: "https://www.swift.org/documentation/")!).text.count) }
            catch { try Task.checkCancellation(); fetch = .failure(WebError.sanitized(error)) }
            return .init(search: search, fetch: fetch)
        }
    }
    public func search(query: String, count: Int = 5) async throws -> WebSearchPage {
        let value = try store.load()
        let connection = try connection(value.searchProvider, settings: value)
        let key = try store.savedKey(connection), client = client
        return try await run(revision: value.revision) {
            try await client.search(provider: connection.provider, base: connection.baseURL, key: key, query: query, count: count)
        }
    }
    public func fetch(url: String, documentID: UUID? = nil, offset: Int = 0, limit: Int = 12_000) async throws -> WebFetchPage {
        let value = try store.load()
        let connection = try connection(value.fetchProvider, settings: value)
        let url = try WebURL.page(url)
        guard offset >= 0, (1...20_000).contains(limit) else { throw WebError.invalidRange }
        pages.removeAll { Date().timeIntervalSince($0.createdAt) > 120 || $0.revision != value.revision }
        if let documentID {
            guard let page = pages.first(where: { $0.id == documentID && ($0.requestedURL == url || $0.document.url == url) && $0.provider == connection.provider }) else {
                throw WebError.expiredDocument
            }
            return try .init(document: page.document, id: page.id, provider: page.provider, offset: offset, limit: limit)
        }
        guard offset == 0 else { throw WebError.expiredDocument }
        if let page = pages.first(where: { $0.requestedURL == url && $0.provider == connection.provider }) {
            return try .init(document: page.document, id: page.id, provider: page.provider, offset: 0, limit: limit)
        }
        let key = try store.savedKey(connection), client = client
        let document = try await run(revision: value.revision) {
            try await client.fetch(provider: connection.provider, base: connection.baseURL, key: key, url: url)
        }
        let page = CachedPage(id: UUID(), requestedURL: url, provider: connection.provider,
            document: document, revision: value.revision, createdAt: Date())
        pages.append(page)
        if pages.count > 2 { pages.removeFirst(pages.count - 2) }
        return try .init(document: document, id: page.id, provider: page.provider, offset: 0, limit: limit)
    }
    private func connection(_ provider: WebProvider?, settings: WebSettings) throws -> WebConnection {
        guard settings.enabled else { throw WebError.disabled }
        guard let provider, let connection = settings.connection(provider) else { throw WebError.notConfigured }
        return connection
    }
    private func cancelRequests() {
        for cancel in cancellations.values { cancel() }
        pages.removeAll()
    }
    private func run<Value: Sendable>(revision: UUID, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard cancellations.count < 2 else { throw WebError.busy }
        let id = UUID(), task = Task { try await operation() }
        cancellations[id] = { task.cancel() }
        defer { cancellations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                try Task.checkCancellation()
                guard try store.load().revision == revision else { throw WebError.cancelled }
                return value
            } catch { throw WebError.sanitized(error) }
        } onCancel: { task.cancel() }
    }
}
