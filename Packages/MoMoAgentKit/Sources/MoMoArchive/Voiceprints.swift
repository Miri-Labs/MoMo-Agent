import Foundation
import MoMoContracts

public struct SpeakerAttribution: Codable, Equatable, Sendable {
    public let clusterID: UUID
    public let personID: UUID?
    public let isUser: Bool
    public let confirmed: Bool
    public let canLearn: Bool
}

public enum SpeakerFeedback: Sendable { case owner, notOwner, person(String), clear }
public enum VoiceprintError: Error, LocalizedError {
    case insufficientSpeech, invalidName
    public var errorDescription: String? {
        switch self {
        case .insufficientSpeech: String(localized: "请选一段至少 3 秒、没有重叠说话的片段来校正声纹。")
        case .invalidName: String(localized: "请输入 1 至 80 个字符的姓名。")
        }
    }
}

struct VoiceprintExample {
    let person: UUID
    let embedding: [Float]
    let positive: Bool
}

enum VoiceprintMatcher {
    // Conservative starting policy, not a calibrated probability. Feedback supplies new exemplars.
    static func match(_ vector: [Float], examples: [VoiceprintExample]) -> UUID? {
        let people = Dictionary(grouping: examples, by: \.person)
        var candidates: [(UUID, Float)] = []
        for (person, samples) in people {
            let positive = samples.filter(\.positive).map { SpeakerEvidence.similarity(vector, $0.embedding) }.max() ?? -1
            let negative = samples.filter { !$0.positive }.map { SpeakerEvidence.similarity(vector, $0.embedding) }.max() ?? -1
            if positive >= 0.75, positive - negative >= 0.04 { candidates.append((person, positive)) }
        }
        candidates.sort { $0.1 > $1.1 }
        guard let best = candidates.first,
              candidates.count == 1 || best.1 - candidates[1].1 >= 0.08 else { return nil }
        return best.0
    }
}

extension ArchiveStore {
    private struct Person {
        let id: UUID
        let name: String
        let owner: Bool
    }
    private func voicePeople() throws -> [Person] {
        try database.rows("SELECT id,name,is_owner FROM voice_profiles ORDER BY id").map {
            Person(id: try $0.requireUUID(0), name: try $0.requireString(1), owner: $0.integer(2) == 1)
        }
    }
    private func voiceExamples(revision: String, people: [Person]) throws -> [VoiceprintExample] {
        var examples: [VoiceprintExample] = []
        for person in people {
            for positive in [true, false] where positive || person.owner {
                let condition = positive ? "o.confirmed_person=?" : "o.rejected_owner=1"
                var args: [SQLValue] = [.text(revision)]
                if positive { args.append(.text(person.id.uuidString)) }
                let query = "SELECT o.span_id,o.evidence FROM speaker_observations o JOIN sessions s ON s.id=o.session_id WHERE s.deleted=0 AND o.model_revision=? AND \(condition)"
                // Keep the original anchors as well as recent corrections; bound matching work on the phone.
                let anchors = try database.rows(query + " ORDER BY o.updated_at ASC,o.span_id LIMIT 8", args)
                let recent = try database.rows(query + " ORDER BY o.updated_at DESC,o.span_id LIMIT 56", args)
                var seen: Set<String> = []
                for row in anchors + recent {
                    guard seen.insert(try row.requireString(0)).inserted else { continue }
                    guard let evidence = try WireJSON.decode(SpeakerEvidence?.self, from: row.requireData(1)),
                          evidence.hasVoiceprint, evidence.cleanSeconds >= 3 else { continue }
                    examples.append(VoiceprintExample(person: person.id, embedding: evidence.embedding, positive: positive))
                }
            }
        }
        return examples
    }

    func attributeSpeaker(spanID: UUID, sessionID: UUID, evidence: SpeakerEvidence?) throws -> (String?, SpeakerAttribution?) {
        guard let evidence, evidence.hasVoiceprint, evidence.cleanSeconds.isFinite,
              evidence.cleanSeconds >= 0, evidence.cleanSeconds <= 30,
              ContentHash.isValid(evidence.modelRevision) else { return (nil, nil) }
        let clusters = try database.rows("SELECT id,centroid,sample_count FROM speaker_clusters WHERE session_id=? AND model_revision=? AND sample_count>0 ORDER BY rowid DESC LIMIT 64",
            [.text(sessionID.uuidString), .text(evidence.modelRevision)])
        var best: (UUID, [Float], Int64, Float)?
        for row in clusters {
            let vector = try WireJSON.decode([Float].self, from: row.requireData(1))
            let score = SpeakerEvidence.similarity(evidence.embedding, vector)
            if score >= 0.75, best == nil || score > best!.3 { best = (try row.requireUUID(0), vector, row.integer(2) ?? 1, score) }
        }
        let cluster = best?.0 ?? UUID()
        var centroid = evidence.embedding
        let count = min(best?.2 ?? 0, 32)
        let canLearn = evidence.cleanSeconds >= 3
        if let best, canLearn {
            centroid = zip(best.1, evidence.embedding).map { ($0 * Float(count) + $1) / Float(count + 1) }
            let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { centroid = centroid.map { $0 / norm } }
        }
        if let best, !canLearn { centroid = best.1 }
        try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET centroid=excluded.centroid,sample_count=excluded.sample_count",
            [.text(cluster.uuidString), .text(sessionID.uuidString), .text(evidence.modelRevision), .blob(try WireJSON.encode(centroid)), .integer(count + (canLearn ? 1 : 0))])
        let people = try voicePeople()
        let person = VoiceprintMatcher.match(evidence.embedding, examples: try voiceExamples(revision: evidence.modelRevision, people: people))
        try database.execute("INSERT INTO speaker_observations(span_id,session_id,cluster_id,model_revision,evidence,matched_person,updated_at) VALUES(?,?,?,?,?,?,?)",
            [.text(spanID.uuidString), .text(sessionID.uuidString), .text(cluster.uuidString), .text(evidence.modelRevision),
             .blob(try WireJSON.encode(evidence)), person.map { .text($0.uuidString) } ?? .null, .double(Date().timeIntervalSince1970)])
        return try speakerLabel(cluster: cluster, personID: person, confirmed: false, learnable: evidence.cleanSeconds >= 3, people: people)
    }

    private func speakerLabel(cluster: UUID, personID: UUID?, confirmed: Bool, learnable: Bool,
                              people: [Person]) throws -> (String?, SpeakerAttribution?) {
        let person = people.first { $0.id == personID }
        let provisional = try database.rows("SELECT sample_count FROM speaker_clusters WHERE id=?", [.text(cluster.uuidString)]).first?.integer(0) == 0
        let number = try database.rows("SELECT COUNT(*) FROM speaker_clusters WHERE sample_count>0 AND session_id=(SELECT session_id FROM speaker_clusters WHERE id=?) AND rowid<=(SELECT rowid FROM speaker_clusters WHERE id=?)",
            [.text(cluster.uuidString), .text(cluster.uuidString)]).first?.integer(0) ?? 0
        let label = person.map { confirmed ? $0.name : String(localized: "可能是\($0.name)") }
            ?? (provisional ? String(localized: "说话人未确定") : String(localized: "说话人 \(number)"))
        return (label, SpeakerAttribution(clusterID: cluster, personID: person?.id, isUser: person?.owner ?? false,
            confirmed: confirmed, canLearn: learnable))
    }

    public func correctSpeaker(_ source: SourceReference, feedback: SpeakerFeedback) throws {
        try correctSpeakers([source], feedback: feedback)
    }

    public func correctSpeakers(_ sources: [SourceReference], feedback: SpeakerFeedback) throws {
        try database.transaction {
            try validateSources(sources)
            var manualClusters: [UUID: UUID] = [:]
            for source in sources {
            let row = try database.rows("SELECT confirmed_person FROM speaker_observations WHERE span_id=? AND session_id=?",
                [.text(source.spanID.uuidString), .text(source.sessionID.uuidString)]).first
            if row == nil {
                if case .clear = feedback { continue }
                // A manual label needs no acoustic evidence. Keep it in a separate namespace,
                // with JSON null evidence, so it can never become a matching exemplar.
                let cluster = manualClusters[source.sessionID] ?? UUID()
                let revision = "manual-label"
                if manualClusters[source.sessionID] == nil {
                    try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,0)",
                        [.text(cluster.uuidString), .text(source.sessionID.uuidString), .text(revision), .blob(try WireJSON.encode([Float]()))])
                    manualClusters[source.sessionID] = cluster
                }
                try database.execute("INSERT INTO speaker_observations(span_id,session_id,cluster_id,model_revision,evidence,updated_at) VALUES(?,?,?,?,?,?)",
                    [.text(source.spanID.uuidString), .text(source.sessionID.uuidString), .text(cluster.uuidString), .text(revision),
                     .blob(try WireJSON.encode(Optional<SpeakerEvidence>.none)), .double(Date().timeIntervalSince1970)])
            }
            var people = try voicePeople()
            func owner() throws -> UUID {
                if let known = people.first(where: \.owner) { return known.id }
                let id = UUID()
                try database.execute("INSERT INTO voice_profiles(id,name,is_owner) VALUES(?,?,1)", [.text(id.uuidString), .text(String(localized: "我"))])
                people = try voicePeople()
                return id
            }
            var person: UUID?
            var rejected = false
            switch feedback {
            case .owner: person = try owner()
            case .notOwner:
                _ = try owner(); rejected = true
                if let previous = row?.string(0).flatMap(UUID.init(uuidString:)), people.contains(where: { $0.id == previous && !$0.owner }) { person = previous }
            case .clear: break
            case .person(let raw):
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VoiceprintError.invalidName }
                if let known = people.first(where: { !$0.owner && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { person = known.id }
                else {
                    person = UUID()
                    try database.execute("INSERT INTO voice_profiles(id,name,is_owner) VALUES(?,?,0)", [.text(person!.uuidString), .text(name)])
                }
                rejected = true
            }
            try database.execute("UPDATE speaker_observations SET confirmed_person=?,rejected_owner=?,updated_at=? WHERE span_id=?",
                [person.map { .text($0.uuidString) } ?? .null, .integer(rejected ? 1 : 0), .double(Date().timeIntervalSince1970), .text(source.spanID.uuidString)])
            }
            try refreshSpeakerMatches()
        }
    }

    public func forgetVoiceprint(personID: UUID) throws {
        try database.transaction {
            let owner = try voicePeople().first { $0.id == personID }?.owner == true
            try database.execute("UPDATE speaker_observations SET confirmed_person=NULL WHERE confirmed_person=?", [.text(personID.uuidString)])
            if owner { try database.execute("UPDATE speaker_observations SET rejected_owner=0") }
            try database.execute("DELETE FROM voice_profiles WHERE id=?", [.text(personID.uuidString)])
            try refreshSpeakerMatches()
        }
    }

    /// Re-evaluate inferred labels after feedback; confirmed labels remain authoritative.
    func refreshSpeakerMatches() throws {
        let people = try voicePeople()
        var examples: [String: [VoiceprintExample]] = [:]
        let sessions = try database.rows("SELECT DISTINCT o.session_id FROM speaker_observations o JOIN sessions s ON s.id=o.session_id WHERE s.deleted=0")
        for session in sessions {
            let id = try session.requireUUID(0)
            guard let document = try currentTranscriptOrNil(sessionID: id) else { continue }
            var updated: [UUID: (String?, SpeakerAttribution?)] = [:]
            for row in try database.rows("SELECT span_id,cluster_id,model_revision,evidence,confirmed_person,rejected_owner FROM speaker_observations WHERE session_id=?", [.text(id.uuidString)]) {
                let revision = try row.requireString(2)
                if examples[revision] == nil { examples[revision] = try voiceExamples(revision: revision, people: people) }
                let evidence = try WireJSON.decode(SpeakerEvidence?.self, from: row.requireData(3))
                let confirmed = row.string(4).flatMap(UUID.init(uuidString:))
                var person = confirmed ?? evidence.flatMap { VoiceprintMatcher.match($0.embedding, examples: examples[revision] ?? []) }
                if row.integer(5) == 1, people.contains(where: { $0.id == person && $0.owner }) { person = nil }
                let span = try row.requireUUID(0)
                updated[span] = try speakerLabel(cluster: row.requireUUID(1), personID: person, confirmed: confirmed != nil,
                    learnable: evidence.map { $0.hasVoiceprint && $0.cleanSeconds >= 3 } ?? false, people: people)
                try database.execute("UPDATE speaker_observations SET matched_person=? WHERE span_id=?", [person.map { .text($0.uuidString) } ?? .null, .text(span.uuidString)])
            }
            let spans = document.spans.map { span in
                guard let value = updated[span.id] else { return span }
                return TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: span.text,
                    speaker: value.0, sourceRanges: span.sourceRanges, attribution: value.1, startsNewSpeakerTurn: span.startsNewSpeakerTurn)
            }
            if spans != document.spans {
                // A label revision invalidates citations but does not cancel unrelated ASR work.
                try storeDocument(TranscriptDocument(sessionID: id, version: document.version + 1,
                    generation: document.generation, spans: spans, updatedAt: Date()), invalidatesExistingSources: true)
            }
        }
    }
}
