import Foundation

/// A locally prepared attachment. Only explicit send admits its content to the selected provider.
public struct AgentAttachment: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, document }
    public struct RecordingReference: Codable, Equatable, Sendable {
        public struct Session: Codable, Equatable, Sendable {
            public let sessionID: UUID
            public let version: Int64
            public let generation: Int64
            public let spanIDs: [UUID]

            public init(sessionID: UUID, version: Int64, generation: Int64, spanIDs: [UUID]) {
                self.sessionID = sessionID; self.version = version; self.generation = generation; self.spanIDs = spanIDs
            }

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id", version, generation, spanIDs = "span_ids"
            }
        }

        public let libraryID: UUID
        public let sessions: [Session]

        public init(libraryID: UUID, sessions: [Session]) {
            self.libraryID = libraryID; self.sessions = sessions
        }

        enum CodingKeys: String, CodingKey {
            case libraryID = "library_id", sessions
        }

        var isValid: Bool {
            !sessions.isEmpty && Set(sessions.map(\.sessionID)).count == sessions.count &&
                sessions.reduce(0, { $0 + $1.spanIDs.count }) <= 4_096 &&
                sessions.allSatisfy {
                    $0.version > 0 && $0.generation >= 0 && !$0.spanIDs.isEmpty &&
                        Set($0.spanIDs).count == $0.spanIDs.count
                }
        }
    }
    public let id: UUID
    public let name: String
    public let kind: Kind
    public let mediaType: String
    public let byteCount: Int
    public let data: Data?
    public let text: String?
    public let preview: Data?
    public let recording: RecordingReference?

    public init(id: UUID = UUID(), name: String, kind: Kind, mediaType: String, byteCount: Int,
                data: Data? = nil, text: String? = nil, preview: Data? = nil, recording: RecordingReference? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.mediaType = mediaType
        self.byteCount = byteCount; self.data = data; self.text = text; self.preview = preview
        self.recording = recording
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, mediaType, media_type, byteCount, byte_count, data, text, preview, recording
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        if let value = try container.decodeIfPresent(String.self, forKey: .mediaType) {
            mediaType = value
        } else {
            mediaType = try container.decode(String.self, forKey: .media_type)
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: .byteCount) {
            byteCount = value
        } else {
            byteCount = try container.decode(Int.self, forKey: .byte_count)
        }
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        preview = try container.decodeIfPresent(Data.self, forKey: .preview)
        recording = try container.decodeIfPresent(RecordingReference.self, forKey: .recording)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(recording, forKey: .recording)
    }

    public static func validate(_ attachments: [Self]) throws {
        guard attachments.count <= 4, Set(attachments.map(\.id)).count == attachments.count,
              attachments.compactMap(\.recording).count <= 1 else { throw AttachmentError.invalid }
        for item in attachments {
            guard !item.name.isEmpty, item.name.utf8.count <= 256,
                  !item.name.contains(where: { $0.isNewline || $0 == "\0" }),
                  (item.recording == nil ? item.byteCount > 0 : item.byteCount == 0),
                  (item.preview?.count ?? 0) <= 64_000 else { throw AttachmentError.invalid }
            if let recording = item.recording {
                guard item.kind == .document, item.data == nil, item.text == nil, item.preview == nil,
                      recording.isValid else { throw AttachmentError.invalid }
                continue
            }
            switch item.kind {
            case .image:
                guard ["image/jpeg", "image/png"].contains(item.mediaType), let data = item.data,
                      !data.isEmpty, data.count <= 1_048_576, item.text == nil else { throw AttachmentError.invalid }
            case .document:
                guard item.data == nil, let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 256_000 else { throw AttachmentError.invalid }
            }
        }
        guard attachments.reduce(0, { $0 + ($1.text?.utf8.count ?? 0) }) <= 256_000 else { throw AttachmentError.invalid }
    }

    public var isHTMLDocument: Bool {
        guard kind == .document else { return false }
        let mime = mediaType.lowercased()
        if mime.contains("html") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    public var isMarkdownDocument: Bool {
        guard kind == .document else { return false }
        let mime = mediaType.lowercased()
        if mime.contains("markdown") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    func strippingRawPayload() -> Self {
        guard data != nil else { return self }
        return Self(id: id, name: name, kind: kind, mediaType: mediaType, byteCount: byteCount,
                    data: nil, text: text, preview: preview)
    }
}

public enum AttachmentError: Error { case invalid }
