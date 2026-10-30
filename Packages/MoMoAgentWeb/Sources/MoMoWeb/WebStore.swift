import Foundation

struct WebStore: Sendable {
    let root: URL
    let credentials: any WebCredentialVault
    var url: URL { root.appendingPathComponent("web-access.json") }

    func load() throws -> WebSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let settings = WebSettings(); try save(settings); return settings
        }
        do {
            let value = try JSONDecoder().decode(WebSettings.self, from: Data(contentsOf: url))
            guard Set(value.connections.map(\.provider)).count == value.connections.count,
                  Set(value.connections.map(\.credentialReference)).count == value.connections.count,
                  Set(value.pendingCredentialRemovals).isDisjoint(with: value.connections.map(\.credentialReference)) else { throw WebError.storage }
            for connection in value.connections { _ = try WebURL.service(connection.baseURL.absoluteString) }
            return value
        } catch { throw WebError.storage }
    }
    func save(_ value: WebSettings) throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch { throw WebError.storage }
    }
    func key(_ draft: WebConnectionDraft, settings: WebSettings) throws -> (URL, String) {
        guard draft.revision == settings.revision else { throw WebError.staleSettings }
        let base = try WebURL.service(draft.address)
        let replacement = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if !replacement.isEmpty { key = replacement }
        else {
            guard let old = settings.connection(draft.provider), old.baseURL == base else { throw WebError.missingKey }
            key = try savedKey(old)
        }
        guard !key.isEmpty, key.utf8.count <= 8192, key.rangeOfCharacter(from: .controlCharacters) == nil else { throw WebError.missingKey }
        return (base, key)
    }
    func savedKey(_ connection: WebConnection) throws -> String {
        let key: String?
        do { key = try credentials.read(connection.credentialReference) }
        catch { throw WebError.credential }
        guard let key, !key.isEmpty else { throw WebError.missingKey }
        return key
    }
    func commit(_ draft: WebConnectionDraft) throws -> WebSettings {
        var settings = try load()
        let (base, key) = try key(draft, settings: settings)
        let old = settings.connection(draft.provider)
        let reference = "momoagent-web-" + UUID().uuidString.lowercased()
        // Reserve cleanup durably before creating a secret; a crash cannot strand an untracked key.
        var reservation = settings
        reservation.pendingCredentialRemovals.append(reference)
        try save(reservation)
        do { try credentials.write(key, reference: reference) }
        catch { _ = cleanup(reservation); throw WebError.credential }
        settings.connections.removeAll { $0.provider == draft.provider }
        settings.connections.append(.init(provider: draft.provider, baseURL: base, credentialReference: reference))
        settings.enabled = true
        if settings.searchProvider == nil { settings.searchProvider = draft.provider }
        if settings.fetchProvider == nil { settings.fetchProvider = draft.provider }
        if let old { settings.pendingCredentialRemovals.append(old.credentialReference) }
        settings.revision = UUID()
        do { try save(settings) }
        catch {
            _ = cleanup(reservation)
            throw error
        }
        return cleanup(settings)
    }
    func remove(_ provider: WebProvider, revision: UUID) throws -> WebSettings {
        var settings = try load()
        guard settings.revision == revision else { throw WebError.staleSettings }
        guard let old = settings.connection(provider) else { return settings }
        settings.connections.removeAll { $0.provider == provider }
        if settings.searchProvider == provider { settings.searchProvider = nil }
        if settings.fetchProvider == provider { settings.fetchProvider = nil }
        settings.pendingCredentialRemovals.append(old.credentialReference)
        settings.revision = UUID(); try save(settings)
        return cleanup(settings)
    }
    func cleanup(_ input: WebSettings) -> WebSettings {
        var value = input
        value.pendingCredentialRemovals = input.pendingCredentialRemovals.filter {
            do { try credentials.write(nil, reference: $0); return false } catch { return true }
        }
        do { try save(value); return value } catch { return input }
    }
}
