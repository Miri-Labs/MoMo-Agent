import Foundation
import Testing
@testable import MoMoArchive

struct ArchiveStorageTests {
    @Test func separatesDownloadsDatabasesModelCachesAndAllTemporaryFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let baseline = try await store.storageUsage(modelDirectory: nil)
        for (path, count) in [
            ("Library/Application Support/MoMoAgent/SpeechModels/revision.partial/model.download", 101),
            ("Library/Caches/MoMoAgent/SpeechModels/model/weights.bin", 203),
            ("Library/Caches/com.momoagent.ios/com.apple.e5rt.e5bundlecache/model/weights.bin", 307),
            ("tmp/MoMoThroughput-test/fixture.wav", 401)
        ] {
            let url = store.rootURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: count).write(to: url)
        }
        let usage = try await store.storageUsage(modelDirectory: nil)
        #expect(usage.modelBytes == baseline.modelBytes + 101)
        #expect(usage.modelCacheBytes == baseline.modelCacheBytes + 510)
        #expect(usage.temporaryBytes == baseline.temporaryBytes + 401)
        #expect(usage.databaseBytes > 0)
        #expect(usage.otherArchiveBytes == baseline.otherArchiveBytes)
        #expect(usage.audioBytes == baseline.audioBytes)
        #expect(usage.totalBytes == baseline.totalBytes + 1012)
    }
    @Test func countsFileLengthsByCategoryWithoutFollowingLinksOrDoubleCountingModels() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let baseline = try await store.storageUsage(modelDirectory: nil)
        let documents = store.rootURL.appendingPathComponent("Documents")
        let models = store.rootURL.appendingPathComponent("Library/Models")
        let exports = store.rootURL.appendingPathComponent("tmp/Exports/test-fixture")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 101).write(to: documents.appendingPathComponent("sample.wav"))
        try Data(repeating: 0, count: 17).write(to: documents.appendingPathComponent("transcript.md"))
        try Data(repeating: 0, count: 203).write(to: models.appendingPathComponent("model.onnx"))
        try Data(repeating: 0, count: 53).write(to: exports.appendingPathComponent("copy.wav"))
        let outside = fixture.root.appendingPathComponent("outside.wav")
        try Data(repeating: 0, count: 499).write(to: outside)
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("linked.wav"), withDestinationURL: outside)
        let usage = try await store.storageUsage(modelDirectory: models)
        #expect(usage.audioBytes == baseline.audioBytes + 101)
        #expect(usage.textBytes == baseline.textBytes + 17)
        #expect(usage.modelBytes == 203)
        #expect(usage.temporaryBytes == baseline.temporaryBytes + 53)
        #expect(usage.otherArchiveBytes == baseline.otherArchiveBytes)
        #expect(usage.totalBytes == baseline.totalBytes + 374)
        #expect(usage.skippedSymbolicLinks == 1)
        #expect(usage.availableBytes.map { $0 >= 0 } != false)
    }

    @Test func pendingInboxAudioCountsAsAudioAndMissingModelsDoNotBecomeReady() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try fixture.deliver(fixture.envelope(), to: store)
        let usage = try await store.storageUsage(modelDirectory: fixture.root.appendingPathComponent("absent-models"))
        #expect(usage.audioBytes == Int64(fixture.audio.count))
        #expect(usage.modelBytes == 0)
    }
}
