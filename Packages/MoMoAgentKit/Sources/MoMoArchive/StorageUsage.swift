import Foundation

public struct ArchiveStorageUsage: Sendable {
    public let measuredAt: Date
    public let audioBytes: Int64
    public let textBytes: Int64
    public let modelBytes: Int64
    public let databaseBytes: Int64
    public let modelCacheBytes: Int64
    public let otherArchiveBytes: Int64
    public let temporaryBytes: Int64
    public let availableBytes: Int64?
    public let skippedSymbolicLinks: Int
    public var totalBytes: Int64 { audioBytes + textBytes + modelBytes + databaseBytes + modelCacheBytes + otherArchiveBytes + temporaryBytes }
}

extension ArchiveStore {
    /// File lengths are a point-in-time estimate, not APFS allocated sizes or a recording-time budget.
    /// Model location is supplied by composition; file presence does not prove a model can run.
    public nonisolated func storageUsage(modelDirectory: URL?) async throws -> ArchiveStorageUsage {
        let root = rootURL
        let worker = Task.detached(priority: .utility) { try StorageUsageReader.read(root: root, modelDirectory: modelDirectory) }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}

enum StorageUsageReader {
    static func read(root: URL, modelDirectory: URL?) throws -> ArchiveStorageUsage {
        var audio: Int64 = 0, text: Int64 = 0, models: Int64 = 0, other: Int64 = 0, exports: Int64 = 0
        var databases: Int64 = 0, modelCaches: Int64 = 0
        var skippedLinks = 0
        let normalizedModel = modelDirectory?.standardizedFileURL
        for name in ["Documents", "Library", "tmp"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            try visit(directory, skip: normalizedModel, skippedLinks: &skippedLinks) { url, size in
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                if relative.hasPrefix("tmp/") { exports += size }
                else if relative.hasPrefix("Library/Application Support/MoMoAgent/SpeechModels/") { models += size }
                else if relative.hasPrefix("Library/Caches/MoMoAgent/SpeechModels/") || relative.hasPrefix("Library/Caches/com.momoagent.ios/com.apple.e5rt.e5bundlecache/") { modelCaches += size }
                else if ["archive.sqlite", "archive.sqlite-wal", "archive.sqlite-shm"].contains(url.lastPathComponent), relative.hasPrefix("Library/Application Support/MoMoAgent/") { databases += size }
                else if url.lastPathComponent == "audio" || ["wav", "m4a", "caf", "aac"].contains(url.pathExtension.lowercased()) { audio += size }
                else if url.lastPathComponent == "transcript.json" || url.lastPathComponent == "transcript.md" || relative.hasPrefix("Documents/workspace/plans/") {
                    text += size
                } else { other += size }
            }
        }
        if let normalizedModel, FileManager.default.fileExists(atPath: normalizedModel.path) {
            try visit(normalizedModel, skip: nil, skippedLinks: &skippedLinks) { _, size in models += size }
        }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        return ArchiveStorageUsage(measuredAt: Date(), audioBytes: audio, textBytes: text, modelBytes: models,
            databaseBytes: databases, modelCacheBytes: modelCaches, otherArchiveBytes: other, temporaryBytes: exports, availableBytes: capacity.map(Int64.init),
            skippedSymbolicLinks: skippedLinks)
    }

    private static func visit(_ url: URL, skip: URL?, skippedLinks: inout Int, file: (URL, Int64) -> Void) throws {
        try Task.checkCancellation()
        guard url.standardizedFileURL != skip else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isSymbolicLink == true { skippedLinks += 1; return }
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try visit(child, skip: skip, skippedLinks: &skippedLinks, file: file)
            }
        } else if values.isRegularFile == true, let size = values.fileSize {
            file(url, Int64(size))
        }
    }
}
