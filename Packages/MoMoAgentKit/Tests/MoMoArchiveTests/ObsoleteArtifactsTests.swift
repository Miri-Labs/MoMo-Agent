import Foundation
import Testing
@testable import MoMoArchive

struct ObsoleteArtifactsTests {
    @Test func removesOnlyLegacyModelsAndExpiredTestRoots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let cache = root.appendingPathComponent("Library/Caches/MoMoAgent/SpeechModels")
        let old = cache.appendingPathComponent(ObsoleteArtifacts.legacyRevision)
        let active = cache.appendingPathComponent("sherpa-coreml-v2-current")
        let partial = root.appendingPathComponent("Library/Application Support/MoMoAgent/SpeechModels/revision.partial")
        let test = root.appendingPathComponent("tmp/MoMoThroughput-\(UUID())")
        let recent = root.appendingPathComponent("tmp/MoMoResourceRecovery-\(UUID())")
        let download = root.appendingPathComponent("tmp/CFNetworkDownload_test.tmp")
        for url in [old, active, partial, test, recent, download] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url.appendingPathComponent("keep"))
        }
        let oldDate = ObsoleteArtifacts.legacyCutoff.addingTimeInterval(-86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: test.path)
        let system = root.appendingPathComponent("Library/Caches/com.momoagent.ios/com.apple.e5rt.e5bundlecache/os/key")
        let stale = system.appendingPathComponent("legacy.tmp.1.bundle")
        let new = system.appendingPathComponent("current.tmp.2.bundle")
        for bundle in [stale, new] {
            let weights = bundle.appendingPathComponent(ObsoleteArtifacts.legacyWeights)
            try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: weights)
            let file = try FileHandle(forWritingTo: weights)
            try file.truncate(atOffset: 235_361_534)
            try file.close()
            if bundle == stale {
                for url in [weights, bundle] { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path) }
            }
        }
        try ObsoleteArtifacts.remove(in: root)
        for url in [old, test, stale] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        for url in [active, partial, recent, download, new] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        try ObsoleteArtifacts.remove(in: root)
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func refusesSymlinkedCacheAncestors() throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        defer { fixture.remove(); outside.remove() }
        let library = fixture.root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Caches"), withDestinationURL: outside.root)
        let old = outside.root.appendingPathComponent("MoMoAgent/SpeechModels/\(ObsoleteArtifacts.legacyRevision)")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try ObsoleteArtifacts.remove(in: fixture.root)
        #expect(FileManager.default.fileExists(atPath: old.path))
    }
}
