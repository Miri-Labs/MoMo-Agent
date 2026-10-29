import Foundation

public enum WebProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseek, exa, tavily
    public var id: String { rawValue }
    public var title: String {
        switch self { case .deepseek: "DeepSeek"; case .exa: "Exa"; case .tavily: "Tavily" }
    }
    public var address: String {
        switch self { case .deepseek: "https://api.deepseek.com"; case .exa: "https://api.exa.ai"; case .tavily: "https://api.tavily.com" }
    }
    public var keyURL: URL {
        switch self {
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .exa: URL(string: "https://dashboard.exa.ai/api-keys")!
        case .tavily: URL(string: "https://app.tavily.com")!
        }
    }
}

public protocol WebCredentialVault: Sendable {
    func read(_ reference: String) throws -> String?
    func write(_ key: String?, reference: String) throws
}

public struct WebConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: WebProvider { provider }
    public let provider: WebProvider
    public let baseURL: URL
    let credentialReference: String
}

public struct WebSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var searchProvider: WebProvider?
    public var fetchProvider: WebProvider?
    public var connections: [WebConnection] = []
    public var revision = UUID()
    var pendingCredentialRemovals: [String] = []
    public init() {}
    public func connection(_ provider: WebProvider) -> WebConnection? { connections.first { $0.provider == provider } }
    public var needsCredentialCleanup: Bool { !pendingCredentialRemovals.isEmpty }
    public var toolNames: [String] {
        guard enabled else { return [] }
        return [("web_search", searchProvider), ("web_fetch", fetchProvider)].compactMap { name, provider in
            provider.flatMap { connection($0) == nil ? nil : name }
        }
    }
}

/// An edit exists only in memory; saved settings never contain an API key.
public struct WebConnectionDraft: Equatable, Sendable {
    public let provider: WebProvider
    public var address: String
    public var apiKey = ""
    public let revision: UUID
    public init(provider: WebProvider, settings: WebSettings) {
        self.provider = provider; revision = settings.revision
        address = settings.connection(provider)?.baseURL.absoluteString ?? provider.address
    }
}

public enum WebError: Error, Equatable, LocalizedError, Sendable {
    case disabled, notConfigured, missingKey, invalidAddress, staleSettings, credential, storage
    case invalidQuery, invalidRange, busy, cancelled, network, timeout, authentication, quota, rateLimited
    case permission, unavailable, invalidResponse, tooLarge, noContent, expiredDocument
    public var errorDescription: String? {
        switch self {
        case .disabled: "联网功能已关闭。"
        case .notConfigured: "请先配置所选的联网服务。"
        case .missingKey: "请填写有效的 API Key；更换服务地址时需要重新填写。"
        case .invalidAddress: "请填写 HTTPS 服务根地址，地址中不能包含账号、密钥、查询参数或接口路径。"
        case .staleSettings: "配置已变化，请返回刷新后重试。"
        case .credential: "无法读写系统钥匙串，请重试。"
        case .storage: "无法读写联网配置，请重试。"
        case .invalidQuery: "搜索词需要为 1–128 个字符，结果数需要为 1–10。"
        case .invalidRange: "网页读取范围无效，请使用返回的下一页位置。"
        case .busy: "联网请求正在处理，请稍后重试。"
        case .cancelled: "联网请求已取消。"
        case .network: "无法连接联网服务，请检查网络。"
        case .timeout: "联网请求超时，请重试。"
        case .authentication: "API Key 无效或已过期。"
        case .quota: "服务账户余额或额度不足。"
        case .rateLimited: "请求过于频繁，请稍后重试。"
        case .permission: "服务拒绝了请求，请检查权限和接口设置。"
        case .unavailable: "联网服务暂时不可用，请稍后重试。"
        case .invalidResponse: "服务返回的数据格式与所选接口不符。"
        case .tooLarge: "返回结果过大，已停止读取。"
        case .noContent: "服务未返回此网页的可读正文。"
        case .expiredDocument: "网页缓存已过期，请从头重新读取。"
        }
    }
    static func sanitized(_ error: Error) -> Self {
        if let value = error as? Self { return value }
        if error is CancellationError { return .cancelled }
        if let value = error as? URLError {
            if value.code == .cancelled { return .cancelled }
            return value.code == .timedOut ? .timeout : .network
        }
        return .invalidResponse
    }
}

public struct WebSearchResult: Codable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public let snippet: String
}

public struct WebSearchPage: Encodable, Sendable {
    public let query: String
    public let provider: WebProvider
    public let results: [WebSearchResult]
    public let contentIsUntrusted = true
}

struct WebDocument: Sendable {
    let title: String
    let url: URL
    let text: String
}

public struct WebFetchPage: Encodable, Sendable {
    public let documentID: UUID
    public let title: String
    public let url: URL
    public let provider: WebProvider
    public let content: String
    public let offset: Int
    public let nextOffset: Int?
    public let totalCharacters: Int
    public let contentIsUntrusted = true
    init(document: WebDocument, id: UUID, provider: WebProvider, offset: Int, limit: Int) throws {
        let total = document.text.count
        guard offset >= 0, offset <= total, (1...20_000).contains(limit) else { throw WebError.invalidRange }
        let start = document.text.index(document.text.startIndex, offsetBy: offset)
        let end = document.text.index(start, offsetBy: min(limit, total - offset))
        documentID = id; title = document.title; url = document.url; self.provider = provider
        content = String(document.text[start..<end]); self.offset = offset; totalCharacters = total
        nextOffset = offset + content.count < total ? offset + content.count : nil
    }
}

public struct WebConnectionTest: Sendable {
    public let search: Result<Int, WebError>
    public let fetch: Result<Int, WebError>
}
