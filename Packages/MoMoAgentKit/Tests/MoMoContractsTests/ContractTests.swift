import Foundation
import Testing
@testable import MoMoContracts

@Test func wireDatesPreserveMillisecondsAndLegacyCanonicalBytes() throws {
    let legacy = Data(#"{"date":"1970-01-01T00:00:01Z"}"#.utf8)
    #expect(try WireJSON.encode(WireJSON.decode(TimestampProbe.self, from: legacy)) == legacy)
    for seconds in [1.625, 1.0001, 1.9999, 1_790_000_000.125, 1_790_000_000.9999] {
        let encoded = try WireJSON.encode(TimestampProbe(date: Date(timeIntervalSince1970: seconds)))
        let decoded = try WireJSON.decode(TimestampProbe.self, from: encoded)
        #expect(abs(decoded.date.timeIntervalSince1970 - seconds) < 0.001)
        #expect(try WireJSON.encode(decoded) == encoded)
    }
    #expect(throws: DecodingError.self) {
        try WireJSON.decode(TimestampProbe.self, from: Data(#"{"date":"not-a-date"}"#.utf8))
    }
}

@Test func wireDatesRemainByteIdenticalDuringConcurrentEncodingAndDecoding() async throws {
    let seconds: [Double] = [0, -1.002, 1.0004, 1.0006, 1_790_000_000, 1_790_000_000.1234]
    try await withThrowingTaskGroup(of: Void.self) { group in
        for worker in 0..<8 {
            group.addTask {
                for index in 0..<24 {
                    let value = seconds[(worker + index) % seconds.count]
                    let milliseconds = (value * 1_000).rounded()
                    let date = Date(timeIntervalSince1970: milliseconds / 1_000)
                    // Compare against the pre-cache implementation, including its whole-second choice.
                    let legacy = ISO8601DateFormatter()
                    legacy.formatOptions = milliseconds.truncatingRemainder(dividingBy: 1_000) == 0
                        ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
                    let expected = Data("{\"date\":\"\(legacy.string(from: date))\"}".utf8)
                    let encoded = try WireJSON.encode(TimestampProbe(date: Date(timeIntervalSince1970: value)))
                    #expect(encoded == expected)
                    #expect(try WireJSON.encode(WireJSON.decode(TimestampProbe.self, from: expected)) == expected)
                }
            }
        }
        try await group.waitForAll()
    }
}

private struct TimestampProbe: Codable, Sendable { let date: Date }

@Test func archiveTimestampFastPathMatchesLegacyDatesAndKeepsOffsetCompatibility() throws {
    for text in ["1970-01-01T00:00:01Z", "2026-10-19T01:20:30.123Z",
                 "2026-10-19T09:20:30+08:00", "2026-10-19T09:20:30.123+08:00",
                 "1969-12-31T23:59:59.998Z", "2000-02-29T00:00:00.001Z"] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        let expected = try #require(formatter.date(from: text))
        let decoded = try WireJSON.decode(TimestampProbe.self, from: Data("{\"date\":\"\(text)\"}".utf8))
        #expect(decoded.date == expected)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for milliseconds in 0..<1_000 {
        let text = String(format: "2026-10-19T01:20:30.%03dZ", milliseconds)
        let decoded = try WireJSON.decode(TimestampProbe.self, from: Data("{\"date\":\"\(text)\"}".utf8))
        #expect(decoded.date == formatter.date(from: text))
    }
}

@Test func rangesRejectOverflowAndUnionWithoutDoubleCounting() throws {
    #expect(throws: ContractError.self) { try FrameRange(start: Int64.max, count: 1) }
    #expect(throws: ContractError.self) { try FrameRange(start: -1, count: 1) }
    let ranges = try [FrameRange(start: 10, count: 10), FrameRange(start: 0, count: 15), FrameRange(start: 25, count: 5)]
    #expect(try FrameRange.union(ranges) == [FrameRange(start: 0, count: 20), FrameRange(start: 25, count: 5)])
    #expect(throws: ContractError.self) {
        try WireJSON.decode(FrameRange.self, from: Data(#"{"start":0,"count":-2}"#.utf8))
    }
}

@Test func envelopeKeepsWireIdentityAndRejectsTampering() throws {
    let manifest = try ChunkManifest(
        sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "test",
        sequence: 0, frames: FrameRange(start: 0, count: 16_000), timebaseHz: 16_000,
        wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 28_800,
        codec: .pcmInt16, sampleRate: 16_000, channels: 1, decodedFrameCount: 16_000,
        byteCount: 32_000, audioSHA256: ContentHash.sha256(Data(repeating: 0, count: 32_000)),
        sealedAt: Date(timeIntervalSince1970: 1), sourceKind: .fixture
    )
    let envelope = try ManifestEnvelope(manifest: manifest)
    let spaced = Data(" \n".utf8) + envelope.manifestData
    let original = try ManifestEnvelope(manifestData: spaced, manifestSHA256: ContentHash.sha256(spaced))
    #expect(original.manifest == envelope.manifest)
    #expect(original.manifestSHA256 != envelope.manifestSHA256)
    #expect(try WireJSON.decode(ManifestEnvelope.self, from: WireJSON.encode(original)) == original)
    #expect(throws: ContractError.hashMismatch) {
        try ManifestEnvelope(manifestData: spaced, manifestSHA256: envelope.manifestSHA256)
    }
    #expect(throws: ContractError.unsupportedVersion(2)) {
        try ManifestEnvelope(manifestData: spaced, manifestSHA256: ContentHash.sha256(spaced), protocolVersion: 2)
    }
}
