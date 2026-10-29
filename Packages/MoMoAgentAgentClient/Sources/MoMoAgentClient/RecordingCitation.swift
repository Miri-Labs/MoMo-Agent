import Foundation

/// App-local recording navigation. Credentials and transcript data never leave AgentClient.
public struct RecordingCitation: Sendable, Identifiable, Equatable {
    public let url: URL
    public let sessionID: UUID
    public let spanID: UUID
    public let version: Int64
    public let generation: Int64
    public var id: String { url.absoluteString }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "momoagent", parts.host?.lowercased() == "source",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty,
              let session = UUID(uuidString: String(path[1])), let span = UUID(uuidString: String(path[2])),
              let query = parts.queryItems, query.count == 2,
              Set(query.map(\.name)) == Set(["version", "generation"]),
              let v = query.first(where: { $0.name == "version" })?.value,
              let g = query.first(where: { $0.name == "generation" })?.value,
              let version = Int64(v), let generation = Int64(g),
              version > 0, generation >= 0, v == String(version), g == String(generation) else { return nil }
        self.url = url; self.sessionID = session; self.spanID = span
        self.version = version; self.generation = generation
    }
}

public struct ResolvedRecordingCitation: Sendable {
    public let source: ContextSource
    public let span: SourceTextSpan
    /// The Mac replica contains current text only; do not present it as a historical snapshot.
    public let showsUpdatedTranscript: Bool
}

public enum RecordingCitationError: LocalizedError {
    case unavailable, ambiguous, changed, invalidPage
    public var errorDescription: String? {
        switch self {
        case .unavailable: "这段录音尚未同步到 Mac，或已被删除。"
        case .ambiguous: "找到多份录音，无法确定这条引用的来源。"
        case .changed: "这条引用的原文已变更或尚未同步。"
        case .invalidPage: "原文读取未完成，请重试。"
        }
    }
}

extension AgentClient {
    public func recordingCitation(_ citation: RecordingCitation) async throws -> ResolvedRecordingCitation {
        var matches: [ContextSource] = []
        var cursor: String?
        var cursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await sources(after: cursor)
            matches += page.items.filter {
                let parts = $0.id.split(separator: "/")
                return parts.count == 2 && UUID(uuidString: String(parts[1])) == citation.sessionID
            }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw RecordingCitationError.invalidPage }
        } while cursor != nil
        guard matches.count == 1, let source = matches.first else {
            throw matches.isEmpty ? RecordingCitationError.unavailable : RecordingCitationError.ambiguous
        }
        let revision = source.revision.split(separator: ":")
        guard revision.count == 4, revision[3] == "0",
              Int64(revision[0]) == citation.generation,
              let version = Int64(revision[1]), version >= citation.version else { throw RecordingCitationError.changed }
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let page = try await sourceText(source, offset: offset, limit: 4000)
            guard page.sourceRevision == source.revision else { throw RecordingCitationError.changed }
            if let span = page.spans?.first(where: { UUID(uuidString: $0.id) == citation.spanID }),
               let text = span.text, !text.isEmpty {
                return ResolvedRecordingCitation(source: source, span: span, showsUpdatedTranscript: version != citation.version)
            }
            guard let next = page.nextOffset else { throw RecordingCitationError.changed }
            guard next > offset, next < page.totalCharacters else { throw RecordingCitationError.invalidPage }
            offset = next
        } while true
    }
}
