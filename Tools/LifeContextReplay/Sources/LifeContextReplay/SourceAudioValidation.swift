import AVFoundation
import Foundation
import MoMoArchive

struct VerifiedAudioSource: Codable {
    let source: SourceReference
    let parts: [VerifiedAudioPart]
}

struct VerifiedAudioPart: Codable {
    let chunkID: UUID
    let sourceStart: Int64
    let frameCount: Int64
    let decodedFrames: Int64
}

enum SourceAudioValidation {
    static func citations(in text: String, allowed: [SourceReference]) throws -> [SourceReference] {
        let pattern = try NSRegularExpression(pattern: #"momoagent://source/[^\s)\]>]+"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { throw LifeContextFailure.answerSourceMismatch }
        return try matches.map { match in
            guard let range = Range(match.range, in: text), let url = URLComponents(string: String(text[range])),
                  let items = url.queryItems, items.count == 2,
                  let versionText = items.first(where: { $0.name == "version" })?.value, let version = Int64(versionText),
                  let generationText = items.first(where: { $0.name == "generation" })?.value, let generation = Int64(generationText) else {
                throw LifeContextFailure.answerSourceMismatch
            }
            let path = url.path.split(separator: "/")
            guard path.count == 2, let session = UUID(uuidString: String(path[0])), let span = UUID(uuidString: String(path[1])) else {
                throw LifeContextFailure.answerSourceMismatch
            }
            let source = SourceReference(sessionID: session, spanID: span, transcriptVersion: version, generation: generation)
            guard allowed.contains(source) else { throw LifeContextFailure.answerSourceMismatch }
            return source
        }
    }

    static func verify(source: SourceReference, archive: ArchiveStore) async throws -> VerifiedAudioSource {
        let document = try await archive.readTranscript(sessionID: source.sessionID)
        guard let span = document.spans.first(where: { $0.id == source.spanID }) else { throw LifeContextFailure.sourceAudioMismatch }
        let parts = try await archive.acquireAudioTimeline(source: source)
        let evidence: [VerifiedAudioPart]
        do {
            guard parts.count == span.sourceRanges.count else { throw LifeContextFailure.sourceAudioMismatch }
            evidence = try zip(parts, span.sourceRanges).map { part, range in
                guard part.lease.chunkID == range.chunkID, part.frames == range.frames else { throw LifeContextFailure.sourceAudioMismatch }
                return try decode(part)
            }
        } catch {
            for part in parts { await archive.releaseAudioLease(id: part.lease.id) }
            throw error
        }
        // No playback lease or file handle survives into the next Agent/API operation.
        for part in parts { await archive.releaseAudioLease(id: part.lease.id) }
        return VerifiedAudioSource(source: source, parts: evidence)
    }

    private static func decode(_ part: AudioPlaybackPart) throws -> VerifiedAudioPart {
        let manifest = part.lease.manifest
        let file = try AVAudioFile(forReading: part.lease.audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let offset = part.frames.start - manifest.frames.start
        guard file.processingFormat.sampleRate == manifest.timebaseHz, offset >= 0,
              part.frames.count > 0, offset + part.frames.count <= file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw LifeContextFailure.sourceAudioMismatch
        }
        file.framePosition = offset
        var remaining = part.frames.count
        while remaining > 0 {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, remaining)))
            guard buffer.frameLength > 0 else { throw LifeContextFailure.sourceAudioMismatch }
            remaining -= Int64(buffer.frameLength)
        }
        return VerifiedAudioPart(chunkID: part.lease.chunkID, sourceStart: part.frames.start,
                                 frameCount: part.frames.count, decodedFrames: part.frames.count - remaining)
    }
}
