import Foundation

extension ArchiveStore {
    public nonisolated func removeObsoleteArtifacts() async throws {
        let root = rootURL
        let worker = Task.detached(priority: .utility) { try ObsoleteArtifacts.remove(in: root) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

enum ObsoleteArtifacts {
    // The full-model Core ML backend was removed at this revision. Sherpa uses separate caches.
    static let legacyCutoff = ISO8601DateFormatter().date(from: "2026-10-20T17:57:28Z")!
    static let legacyRevision = "1f2deee388f1ca1041915536f3f388f6b4d8774ea79a1ec52b2ee4333508897f"
    static let legacyWeights = "H18.bundle/main_language_1_1_1_1_1_speech_1_1_1_128_560_speech_lengths_1_1_1_1_1_textnorm_1_1_1_1_1_/main_ane/ane_mil_model/weights1.bin"

    static func remove(in root: URL, now: Date = Date()) throws {
        let manager = FileManager.default
        let caches = root.appendingPathComponent("Library/Caches")
        let marker = caches.appendingPathComponent("MoMoAgent/legacy-model-cleanup-v1")
        guard try isUnlinkedPath(marker, inside: root),
              try isUnlinkedPath(caches.appendingPathComponent("MoMoAgent/SpeechModels"), inside: root),
              try isUnlinkedPath(caches.appendingPathComponent("com.momoagent.ios/com.apple.e5rt.e5bundlecache"), inside: root),
              try isUnlinkedPath(root.appendingPathComponent("tmp"), inside: root) else { return }
        if !manager.fileExists(atPath: marker.path) {
            let models = caches.appendingPathComponent("MoMoAgent/SpeechModels")
            for old in try directories(models) where old.lastPathComponent == legacyRevision {
                try Task.checkCancellation()
                try manager.removeItem(at: old)
            }
            let system = caches.appendingPathComponent("com.momoagent.ios/com.apple.e5rt.e5bundlecache")
            for os in try directories(system) {
                for identity in try directories(os) {
                    for bundle in try directories(identity) where bundle.lastPathComponent.contains(".tmp.") && bundle.pathExtension == "bundle" {
                        try Task.checkCancellation()
                        let weights = bundle.appendingPathComponent(legacyWeights)
                        guard try isUnlinkedPath(weights, inside: root), manager.fileExists(atPath: weights.path) else { continue }
                        let values = try weights.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                        let bundleDate = try bundle.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        guard values.isRegularFile == true, values.fileSize == 235_361_534,
                              let date = values.contentModificationDate, date < legacyCutoff,
                              let bundleDate, bundleDate < legacyCutoff else { continue }
                        try manager.removeItem(at: bundle)
                    }
                }
            }
            try manager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("1".utf8).write(to: marker, options: .atomic)
        }
        // Tests have unique roots; leave recent runs and unrelated downloads alone.
        for directory in try directories(root.appendingPathComponent("tmp")) {
            let name = directory.lastPathComponent
            guard let prefix = ["MoMoThroughput-", "MoMoResourceRecovery-"].first(where: { name.hasPrefix($0) }),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let date = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > 86_400 else { continue }
            try Task.checkCancellation()
            try manager.removeItem(at: directory)
        }
    }

    private static func directories(_ url: URL) throws -> [URL] {
        guard try isUnlinkedPath(url, inside: url.deletingLastPathComponent()) else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func isUnlinkedPath(_ url: URL, inside root: URL) throws -> Bool {
        var current = url.standardizedFileURL
        let root = root.standardizedFileURL
        guard current.path.hasPrefix(root.path + "/") else { return false }
        while current != root {
            do { if try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return false } }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { }
            current.deleteLastPathComponent()
        }
        return true
    }
}
