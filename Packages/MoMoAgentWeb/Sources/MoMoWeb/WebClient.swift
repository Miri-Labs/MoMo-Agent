import Foundation

/// All provider-specific wire formats end here. Callers receive the same search/page types.
struct WebClient: Sendable {
    var http = WebHTTP()
    func search(provider: WebProvider, base: URL, key: String, query: String, count: Int) async throws -> WebSearchPage {
        let request = try Self.searchRequest(provider: provider, base: base, key: key, query: query, count: count)
        let data = try await http.execute(request)
        return try Self.searchPage(data, provider: provider, query: query, count: count)
    }
    func fetch(provider: WebProvider, base: URL, key: String, url: URL) async throws -> WebDocument {
        let request = try Self.fetchRequest(provider: provider, base: base, key: key, url: url)
        let data = try await http.execute(request)
        return try Self.document(data, provider: provider, requestedURL: url)
    }
    static func searchRequest(provider: WebProvider, base: URL, key: String, query: String, count: Int) throws -> URLRequest {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.unicodeScalars.count <= 128, (1...10).contains(count) else { throw WebError.invalidQuery }
        switch provider {
        case .deepseek: return try request(provider, base, "v1/tools/search", key, ["query": query, "count": count, "need_content": false])
        case .exa: return try request(provider, base, "search", key, ["query": query, "numResults": count, "type": "auto", "contents": ["highlights": true]])
        case .tavily: return try request(provider, base, "search", key, ["query": query, "max_results": count, "search_depth": "basic", "include_answer": false, "include_raw_content": false])
        }
    }
    static func fetchRequest(provider: WebProvider, base: URL, key: String, url: URL) throws -> URLRequest {
        _ = try WebURL.page(url.absoluteString)
        switch provider {
        case .deepseek: return try request(provider, base, "v1/tools/fetch", key, ["url": url.absoluteString])
        case .exa: return try request(provider, base, "contents", key, ["urls": [url.absoluteString], "text": true])
        case .tavily: return try request(provider, base, "extract", key, ["urls": [url.absoluteString], "extract_depth": "basic", "format": "markdown"])
        }
    }
    private static func request(_ provider: WebProvider, _ base: URL, _ path: String, _ key: String, _ body: [String: Any]) throws -> URLRequest {
        _ = try WebURL.service(base.absoluteString)
        guard !key.isEmpty, key.utf8.count <= 8192, key.rangeOfCharacter(from: .controlCharacters) == nil else { throw WebError.missingKey }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(provider == .exa ? key : "Bearer " + key, forHTTPHeaderField: provider == .exa ? "x-api-key" : "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func searchPage(_ data: Data, provider: WebProvider, query: String, count: Int) throws -> WebSearchPage {
        do {
            let results: [WebSearchResult]
            switch provider {
            case .deepseek:
                results = try JSONDecoder().decode(DeepSearch.self, from: data).results.prefix(count).map {
                    try result($0.title, $0.url, $0.summary)
                }
            case .exa:
                results = try JSONDecoder().decode(ExaSearch.self, from: data).results.prefix(count).map {
                    try result($0.title, $0.url, $0.highlights?.joined(separator: "\n") ?? "")
                }
            case .tavily:
                results = try JSONDecoder().decode(TavilySearch.self, from: data).results.prefix(count).map {
                    try result($0.title, $0.url, $0.content)
                }
            }
            return .init(query: query, provider: provider, results: results)
        } catch { throw WebError.sanitized(error) }
    }
    private static func result(_ title: String, _ url: String, _ snippet: String) throws -> WebSearchResult {
        .init(title: String(title.prefix(512)), url: try WebURL.page(url), snippet: String(snippet.prefix(2000)))
    }
    static func document(_ data: Data, provider: WebProvider, requestedURL: URL) throws -> WebDocument {
        do {
            let title: String, text: String, url: URL
            switch provider {
            case .deepseek:
                let value = try JSONDecoder().decode(DeepDocument.self, from: data)
                title = value.title; text = value.content; url = requestedURL
            case .exa:
                let value = try JSONDecoder().decode(ExaContents.self, from: data)
                guard let item = value.results.first else { throw WebError.noContent }
                title = item.title ?? ""; text = item.text ?? ""; url = try WebURL.page(item.url)
            case .tavily:
                let value = try JSONDecoder().decode(TavilyContents.self, from: data)
                guard let item = value.results.first else { throw WebError.noContent }
                title = ""; text = item.raw_content; url = try WebURL.page(item.url)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebError.noContent }
            return .init(title: String(title.prefix(512)), url: url, text: text)
        } catch { throw WebError.sanitized(error) }
    }
    private struct DeepSearch: Decodable { let results: [Item]; struct Item: Decodable { let title: String; let url: String; let summary: String } }
    private struct ExaSearch: Decodable { let results: [Item]; struct Item: Decodable { let title: String; let url: String; let highlights: [String]? } }
    private struct TavilySearch: Decodable { let results: [Item]; struct Item: Decodable { let title: String; let url: String; let content: String } }
    private struct DeepDocument: Decodable { let title: String; let content: String }
    private struct ExaContents: Decodable { let results: [Item]; struct Item: Decodable { let title: String?; let url: String; let text: String? } }
    private struct TavilyContents: Decodable { let results: [Item]; struct Item: Decodable { let url: String; let raw_content: String } }
}
