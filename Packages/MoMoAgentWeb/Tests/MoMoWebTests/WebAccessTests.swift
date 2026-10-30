import Foundation
import Testing
@testable import MoMoWeb

private final class Vault: WebCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failDelete = false
    private var afterWrite: (@Sendable (String) throws -> Void)?
    func read(_ reference: String) throws -> String? { lock.withLock { values[reference] } }
    func write(_ key: String?, reference: String) throws {
        let hook = try lock.withLock {
            if key == nil && failDelete { throw WebError.credential }
            values[reference] = key
            return afterWrite
        }
        if let key { try hook?(key) }
    }
    func failingDeletes(_ value: Bool) { lock.withLock { failDelete = value } }
    func afterWriting(_ hook: @escaping @Sendable (String) throws -> Void) { lock.withLock { afterWrite = hook } }
    var count: Int { lock.withLock { values.count } }
}

@Test func interruptedCredentialCommitRetainsDurableCleanupReferenceAndPreviousConnection() throws {
    let root = try root(); defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    let vault = Vault(), store = WebStore(root: root, credentials: vault)
    var original = WebConnectionDraft(provider: .deepseek, settings: try store.load()); original.apiKey = "synthetic-working"
    let first = try store.commit(original)
    vault.failingDeletes(true)
    vault.afterWriting { key in
        if key == "synthetic-interrupted" {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        }
    }
    var replacement = WebConnectionDraft(provider: .deepseek, settings: first); replacement.apiKey = "synthetic-interrupted"
    #expect(throws: WebError.storage) { try store.commit(replacement) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let recoverable = try store.load()
    #expect(recoverable.needsCredentialCleanup && vault.count == 2)
    #expect(try store.savedKey(#require(recoverable.connection(.deepseek))) == "synthetic-working")
    vault.failingDeletes(false)
    let recovered = store.cleanup(recoverable)
    #expect(!recovered.needsCredentialCleanup && vault.count == 1)
}

private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("momo-web-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}

@Test(arguments: WebProvider.allCases)
func savingAConnectionImmediatelyProvidesBothTools(_ provider: WebProvider) async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let vault = Vault(), access = WebAccess(root: root, credentials: vault)
    let initial = try await access.settings()
    #expect(initial.toolNames.isEmpty)
    var draft = WebConnectionDraft(provider: provider, settings: initial)
    await #expect(throws: WebError.missingKey) { try await access.save(draft) }
    #expect(try await access.settings().toolNames.isEmpty)
    draft.apiKey = "synthetic"
    let saved = try await access.save(draft)
    #expect(saved.enabled && saved.searchProvider == provider && saved.fetchProvider == provider)
    #expect(saved.toolNames == ["web_search", "web_fetch"])
    let reopened = WebAccess(root: root, credentials: vault)
    #expect(try await reopened.settings().toolNames == saved.toolNames)
}

@Test func savingKeepsSelectedServicesAndActivatesPreviouslyUnassignedConfiguration() async throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let access = WebAccess(root: root, credentials: Vault())
    var first = WebConnectionDraft(provider: .exa, settings: try await access.settings()); first.apiKey = "synthetic-exa"
    let saved = try await access.save(first)
    var second = WebConnectionDraft(provider: .tavily, settings: saved); second.apiKey = "synthetic-tavily"
    let both = try await access.save(second)
    #expect(both.searchProvider == .exa && both.fetchProvider == .exa)
    let selected = try await access.update(enabled: false, search: .exa, fetch: .tavily, revision: both.revision)
    #expect(selected.toolNames.isEmpty)
    let activated = try await access.save(WebConnectionDraft(provider: .exa, settings: selected))
    #expect(activated.enabled && activated.searchProvider == .exa && activated.fetchProvider == .tavily)
    let legacy = try await access.update(enabled: false, search: nil, fetch: nil, revision: activated.revision)
    let resaved = try await access.save(WebConnectionDraft(provider: .tavily, settings: legacy))
    #expect(resaved.searchProvider == .tavily && resaved.fetchProvider == .tavily)
    #expect(resaved.toolNames == ["web_search", "web_fetch"])
}

@Test func providerRequestsUseIndependentOfficialContractsAndKeepKeysOutOfBodies() throws {
    for provider in WebProvider.allCases {
        let base = try #require(URL(string: provider.address))
        let search = try WebClient.searchRequest(provider: provider, base: base, key: "synthetic-secret", query: "Swift", count: 3)
        let fetch = try WebClient.fetchRequest(provider: provider, base: base, key: "synthetic-secret", url: #require(URL(string: "https://example.com/article")))
        #expect(search.httpMethod == "POST" && fetch.httpMethod == "POST")
        let searchBody = try #require(search.httpBody), fetchBody = try #require(fetch.httpBody)
        #expect(!String(decoding: searchBody, as: UTF8.self).contains("synthetic-secret"))
        #expect(!String(decoding: fetchBody, as: UTF8.self).contains("synthetic-secret"))
        let body = try #require(JSONSerialization.jsonObject(with: searchBody) as? [String: Any])
        switch provider {
        case .deepseek:
            #expect(search.url?.path == "/v1/tools/search" && fetch.url?.path == "/v1/tools/fetch")
            #expect(body["count"] as? Int == 3 && body["need_content"] as? Bool == false)
            #expect(search.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-secret")
        case .exa:
            #expect(search.url?.path == "/search" && fetch.url?.path == "/contents")
            #expect(body["numResults"] as? Int == 3)
            #expect(search.value(forHTTPHeaderField: "x-api-key") == "synthetic-secret")
            #expect(search.value(forHTTPHeaderField: "Authorization") == nil)
        case .tavily:
            #expect(search.url?.path == "/search" && fetch.url?.path == "/extract")
            #expect(body["max_results"] as? Int == 3 && body["search_depth"] as? String == "basic")
        }
    }
    #expect(throws: WebError.invalidQuery) {
        try WebClient.searchRequest(provider: .deepseek, base: #require(URL(string: WebProvider.deepseek.address)), key: "synthetic", query: String(repeating: "a", count: 129), count: 5)
    }
    #expect(throws: WebError.invalidAddress) { try WebURL.service("https://secret@example.com?key=private") }
    #expect(throws: WebError.invalidAddress) { try WebURL.page("file:///private/file") }
}

@Test func providerResponsesNormalizeAtTheBoundaryAndRejectWrongSchemas() throws {
    let fixtures: [(WebProvider, String, String)] = [
        (.deepseek, #"{"results":[{"title":"Page","url":"https://example.com/article","summary":"Evidence"}]}"#, #"{"title":"Page","content":"A readable page"}"#),
        (.exa, #"{"results":[{"title":"Page","url":"https://example.com/article","highlights":["Evidence"]}]}"#, #"{"results":[{"title":"Page","url":"https://example.com/article","text":"A readable page"}]}"#),
        (.tavily, #"{"results":[{"title":"Page","url":"https://example.com/article","content":"Evidence"}]}"#, #"{"results":[{"url":"https://example.com/article","raw_content":"A readable page"}],"failed_results":[]}"#)
    ]
    for (provider, search, fetch) in fixtures {
        let results = try WebClient.searchPage(Data(search.utf8), provider: provider, query: "test", count: 5)
        #expect(results.results.count == 1 && results.results[0].snippet == "Evidence")
        let doc = try WebClient.document(Data(fetch.utf8), provider: provider, requestedURL: #require(URL(string: "https://example.com/article")))
        #expect(doc.text == "A readable page")
        #expect(try WebClient.searchPage(Data(#"{"results":[]}"#.utf8), provider: provider, query: "nothing", count: 5).results.isEmpty)
        #expect(throws: WebError.invalidResponse) { try WebClient.searchPage(Data(#"{"secret":"private-response-body"}"#.utf8), provider: provider, query: "test", count: 5) }
    }
    #expect(throws: WebError.noContent) {
        try WebClient.document(Data(#"{"results":[],"failed_results":[{"url":"https://example.com","error":"blocked"}]}"#.utf8), provider: .tavily, requestedURL: #require(URL(string: "https://example.com")))
    }
}

@Test func settingsKeepSecretsSeparateAndRotateWithoutOverwritingWorkingCredentials() throws {
    let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
    let vault = Vault(), store = WebStore(root: root, credentials: vault)
    var draft = WebConnectionDraft(provider: .deepseek, settings: try store.load()); draft.apiKey = "synthetic-first"
    let first = try store.commit(draft)
    #expect(!String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains("synthetic-first"))
    #expect(throws: WebError.staleSettings) { try store.commit(draft) }
    let unchanged = WebConnectionDraft(provider: .deepseek, settings: first)
    #expect(try store.key(unchanged, settings: first).1 == "synthetic-first")
    var moved = unchanged; moved.address = "https://another.example.com"
    #expect(throws: WebError.missingKey) { try store.key(moved, settings: first) }
    vault.failingDeletes(true)
    var replacement = unchanged; replacement.apiKey = "synthetic-second"
    let second = try store.commit(replacement)
    #expect(second.needsCredentialCleanup && vault.count == 2)
    #expect(try store.savedKey(#require(second.connection(.deepseek))) == "synthetic-second")
    vault.failingDeletes(false)
    let cleaned = store.cleanup(second)
    #expect(!cleaned.needsCredentialCleanup && vault.count == 1)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    var failed = WebConnectionDraft(provider: .deepseek, settings: cleaned); failed.apiKey = "synthetic-third"
    #expect(throws: WebError.storage) { try store.commit(failed) }
    #expect(try store.savedKey(#require(cleaned.connection(.deepseek))) == "synthetic-second" && vault.count == 1)
}

private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    var handler: @Sendable (URLRequest) -> (Int, String?) = { _ in (200, "{}") }
    private var requests = 0
    private var stopped = 0
    func reset(_ handler: @escaping @Sendable (URLRequest) -> (Int, String?)) {
        lock.withLock { self.handler = handler; requests = 0; stopped = 0 }
    }
    func response(_ request: URLRequest) -> (Int, String?) {
        let handler = lock.withLock { requests += 1; return self.handler }; return handler(request)
    }
    func stop() { lock.withLock { stopped += 1 } }
    var count: Int { lock.withLock { requests } }
}

private final class Fixture: URLProtocol, @unchecked Sendable {
    static let state = FixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.response(request)
        guard let body else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.stop() }
}

private func accessFixture() async throws -> (URL, WebAccess, WebSettings) {
    let root = try root(), vault = Vault()
    let access = WebAccess(root: root, credentials: vault, http: .init(configuration: {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [Fixture.self]; return value
    }))
    var draft = WebConnectionDraft(provider: .deepseek, settings: try await access.settings()); draft.apiKey = "synthetic"
    let saved = try await access.save(draft)
    return (root, access, saved)
}

private func waitForRequests(_ count: Int) async throws {
    for _ in 0..<100 {
        if Fixture.state.count >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw WebError.timeout
}

@Suite(.serialized) struct NetworkAndCancellationTests {
    @Test func streamedResponseSizeIsBoundedEvenWithoutAContentLength() async throws {
        let body = "{\"title\":\"large\",\"content\":\"" + String(repeating: "a", count: 2 * 1024 * 1024) + "\"}"
        Fixture.state.reset { _ in (200, body) }
        let (root, access, _) = try await accessFixture(); defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: WebError.tooLarge) { try await access.fetch(url: "https://example.com/large") }
    }
    @Test func fetchPagingUsesOneSnapshotAndConfigurationChangeRevokesIt() async throws {
        let text = String(repeating: "鹅卵石🪨", count: 30)
        Fixture.state.reset { _ in (200, String(decoding: try! JSONSerialization.data(withJSONObject: ["title": "Page", "content": text]), as: UTF8.self)) }
        let (root, access, settings) = try await accessFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await access.fetch(url: "https://example.com", limit: 11)
        let second = try await access.fetch(url: "https://example.com", documentID: first.documentID, offset: #require(first.nextOffset), limit: 20_000)
        #expect(first.content + second.content == text && second.nextOffset == nil && Fixture.state.count == 1)
        #expect(settings.toolNames == ["web_search", "web_fetch"])
        let disabled = try await access.update(enabled: false, search: .deepseek, fetch: .deepseek, revision: settings.revision)
        #expect(disabled.toolNames.isEmpty)
        await #expect(throws: WebError.disabled) { try await access.search(query: "test") }
        _ = try await access.update(enabled: true, search: .deepseek, fetch: .deepseek, revision: disabled.revision)
        await #expect(throws: WebError.expiredDocument) { try await access.fetch(url: "https://example.com", documentID: first.documentID, offset: 11) }
    }

    @Test func disablingCancelsRunningRequestAndBoundsConcurrentWork() async throws {
        Fixture.state.reset { _ in (200, nil) }
        let (root, access, settings) = try await accessFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await access.search(query: "one") }
        let second = Task { try await access.search(query: "two") }
        try await waitForRequests(2)
        await #expect(throws: WebError.busy) { try await access.search(query: "three") }
        _ = try await access.update(enabled: false, search: .deepseek, fetch: .deepseek, revision: settings.revision)
        await #expect(throws: WebError.cancelled) { try await first.value }
        await #expect(throws: WebError.cancelled) { try await second.value }
        #expect(Fixture.state.count == 2)
    }

    @Test func httpErrorsAreSanitizedAndCallerCancellationReleasesRequestSlot() async throws {
        let (root, access, _) = try await accessFixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (status, expected) in [(401, WebError.authentication), (402, .quota), (403, .permission), (429, .rateLimited), (504, .timeout)] {
            Fixture.state.reset { _ in (status, #"{"private":"never copy this body"}"#) }
            await #expect(throws: expected) { try await access.search(query: "public") }
        }
        Fixture.state.reset { _ in (200, nil) }
        let task = Task { try await access.search(query: "cancel") }
        try await waitForRequests(1); task.cancel()
        await #expect(throws: WebError.cancelled) { try await task.value }
        Fixture.state.reset { _ in (200, #"{"results":[]}"#) }
        #expect(try await access.search(query: "new").results.isEmpty)
    }
}
