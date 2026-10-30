import Foundation
import OSLog
import MoMoArchive
import MoMoContracts

/// Utility-priority callers decode one leased file at a time. Cache memory is capped at 64 × 256 RMS bins.
actor PlaybackWaveformCache {
    struct Update: Sendable {
        let bins: [Float]
        let progress: Double
        let loadedThrough: Double
    }
    private struct Key: Hashable, Codable {
        let library: UUID
        let session: UUID
        let generation: Int64
        let manifest: String
        let start: Int64
        let count: Int64
        let file: PlaybackPreviewFileStamp
    }
    private var entries: [Key: [Float]] = [:]
    private var recency: [Key] = []
    private var writesSincePrune = 0
    private var preparationGeneration: UUID?
    private var persistedKeys: Set<Key> = []
    private let directory: URL?
    private let logger = Logger(subsystem: "com.momoagent.ios", category: "waveform-cache")
    #if DEBUG
    private(set) var decodedPartCount = 0
    #endif

    init(directory: URL? = nil) { self.directory = directory }

    func preparationIdentity() throws -> UUID {
        if let preparationGeneration { return preparationGeneration }
        guard let directory else { throw PlaybackError.unavailable }
        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        try? FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
        let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writeOptions: Data.WritingOptions = [.atomic]
        #endif
        let url = directory.appendingPathComponent("preparation-generation")
        let id: UUID
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8), let stored = UUID(uuidString: text) {
                id = stored
                #if os(iOS)
                try? FileManager.default.setAttributes(protection, ofItemAtPath: url.path)
                #endif
            } else {
                id = UUID()
                try Data(id.uuidString.utf8).write(to: url, options: writeOptions)
            }
        } else {
            id = UUID()
            try Data(id.uuidString.utf8).write(to: url, options: writeOptions)
        }
        preparationGeneration = id
        return id
    }

    private nonisolated static func decodeEnvelope(part: AudioPlaybackPart) throws -> [Float] {
        try PlaybackPCMReader(part: part).envelope(binCount: 256)
    }

    func waveform(for timeline: PlaybackTimeline, archive: ArchiveStore,
                  progress: (@Sendable (Update) async -> Void)? = nil, requirePersistence: Bool = false) async throws -> [Float] {
        do {
            let result = try await readWaveform(for: timeline, archive: archive, progress: progress, requirePersistence: requirePersistence)
            try await archive.cleanDeletedFiles()
            pruneDisk()
            return result
        } catch {
            let original = error
            // A deletion can wait on the just-released decoder lease. Cancellation and
            // identity failures must still finish that cleanup and bound the derived cache.
            do { try await archive.cleanDeletedFiles() }
            catch {
                let failure = error as NSError
                logger.error("Waveform cleanup failed: \(failure.domain, privacy: .public) / \(failure.code)")
            }
            pruneDisk()
            throw original
        }
    }

    private func readWaveform(for timeline: PlaybackTimeline, archive: ArchiveStore,
                              progress: (@Sendable (Update) async -> Void)?, requirePersistence: Bool) async throws -> [Float] {
        guard let duration = timeline.duration, duration > 0,
              timeline.segments.contains(where: { $0.part.audioAvailable }) else { return [] }
        let binCount = 512
        var sums = [Double](repeating: 0, count: binCount)
        var weights = [Double](repeating: 0, count: binCount)
        let total = timeline.segments.filter { $0.part.audioAvailable }.count
        var stamps: [[UUID: PlaybackPreviewFileStamp]] = []
        for member in timeline.archives { stamps.append(try await archive.playbackPreviewFileStamps(in: member)) }
        var completed = 0
        var lastPublication: ContinuousClock.Instant?
        for segment in timeline.segments where segment.part.audioAvailable {
            try Task.checkCancellation()
            let member = timeline.archives[segment.archiveIndex]
            guard let stamp = stamps[segment.archiveIndex][segment.part.manifest.chunkID] else { throw PlaybackError.unavailable }
            let key = Key(library: archive.libraryInstanceID, session: segment.part.manifest.sessionID,
                generation: member.generation, manifest: segment.part.manifestSHA256,
                start: segment.part.frames.start, count: segment.part.frames.count, file: stamp)
            let values: [Float]
            if let cached = entries[key] ?? readDisk(key) {
                values = cached
                entries[key] = cached
            } else {
                let part = try await archive.acquirePlaybackPart(segment.part, in: member)
                do {
                    values = try await Task.detached(priority: Task.currentPriority) {
                        try Self.decodeEnvelope(part: part)
                    }.value
                    #if DEBUG
                    decodedPartCount += 1
                    #endif
                } catch {
                    await archive.releaseAudioLease(id: part.lease.id)
                    throw error
                }
                await archive.releaseAudioLease(id: part.lease.id)
                // File handles and the lease are released before awaiting another archive turn.
                let current = try await archive.playbackPreviewFileStamp(for: segment.part, in: member)
                try Task.checkCancellation()
                guard current == stamp else { throw PlaybackError.unavailable }
                entries[key] = values
                writeDisk(values, key: key)
            }
            if requirePersistence, !persistedKeys.contains(key) {
                writeDisk(values, key: key)
                guard persistedKeys.contains(key) else { throw PlaybackError.unavailable }
            }
            recency.removeAll { $0 == key }
            recency.append(key)
            while recency.count > 64 {
                let evicted = recency.removeFirst()
                entries.removeValue(forKey: evicted); persistedKeys.remove(evicted)
            }
            let step = (segment.end - segment.start) / Double(values.count)
            for (index, value) in values.enumerated() {
                let lower = segment.start + Double(index) * step
                let upper = min(segment.end, lower + step)
                let first = max(0, min(binCount - 1, Int(lower / duration * Double(binCount))))
                let last = max(first, min(binCount - 1, Int(upper / duration * Double(binCount))))
                for bin in first...last {
                    let overlap = max(0, min(upper, Double(bin + 1) / Double(binCount) * duration)
                        - max(lower, Double(bin) / Double(binCount) * duration))
                    sums[bin] += Double(value) * Double(value) * overlap
                    weights[bin] += overlap
                }
            }
            completed += 1
            let now = ContinuousClock.now
            let publicationDue = lastPublication.map { $0.duration(to: now) >= .milliseconds(150) } ?? true
            if let progress, completed == total || publicationDue {
                // The decoder/file is already closed and its lease released before UI delivery.
                // Recheck every member's identity before publishing any derived data.
                for member in timeline.archives { try await archive.validatePlaybackTimeline(member) }
                try Task.checkCancellation()
                await progress(.init(bins: bins(sums, weights), progress: Double(completed) / Double(total),
                                     loadedThrough: segment.end))
                lastPublication = now
            }
        }
        try Task.checkCancellation()
        for (index, member) in timeline.archives.enumerated() {
            guard try await archive.playbackPreviewFileStamps(in: member) == stamps[index] else { throw PlaybackError.unavailable }
        }
        return bins(sums, weights)
    }

    private func bins(_ sums: [Double], _ weights: [Double]) -> [Float] {
        sums.indices.map { weights[$0] > 0 ? Float(sqrt(sums[$0] / weights[$0])) : 0 }
    }

    private func cacheURL(_ key: Key, extension suffix: String = "wfm") throws -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try directory?.appendingPathComponent(ContentHash.sha256(encoder.encode(key)) + "." + suffix)
    }

    private func readDisk(_ key: Key) -> [Float]? {
        do {
            guard let binary = try cacheURL(key), let legacy = try cacheURL(key, extension: "json") else { return nil }
            let url = FileManager.default.fileExists(atPath: binary.path) ? binary : legacy
            guard FileManager.default.fileExists(atPath: url.path),
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384 else { return nil }
            let data = try Data(contentsOf: url)
            let values: [Float]
            if url.pathExtension == "wfm" {
                guard data.count == 1_028, data.prefix(4) == Data([87, 70, 77, 1]) else { return nil }
                values = (0..<256).map { index in
                    let offset = 4 + index * 4
                    let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                        | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
                    return Float(bitPattern: bits)
                }
            } else { values = try JSONDecoder().decode([Float].self, from: data) }
            guard values.count == 256, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            persistedKeys.insert(key)
            return values
        } catch { return nil } // Derived cache damage is repaired from the verified original.
    }

    private func writeDisk(_ values: [Float], key: Key) {
        do {
            guard let directory, let url = try cacheURL(key) else { return }
            #if os(iOS)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let options: Data.WritingOptions = [.atomic]
            #endif
            // Fixed little-endian Float32 bins: 1,028 bytes, lossless relative to the RMS values.
            // Original audio and citation frame boundaries are untouched.
            var data = Data([87, 70, 77, 1])
            for value in values {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            try data.write(to: url, options: options)
            persistedKeys.insert(key)
            writesSincePrune += 1
            if writesSincePrune >= 256 { pruneDisk() }
        } catch { logger.notice("Optional waveform disk cache unavailable") }
    }

    private func pruneDisk() {
        do {
            guard let directory, writesSincePrune >= 256 else { return }
            writesSincePrune = 0
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "json" || $0.pathExtension == "wfm" }
            if files.count > 16_384 {
                let ordered = try files.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
                    .sorted { $0.1 < $1.1 }
                for (file, _) in ordered.prefix(files.count - 16_384) { try FileManager.default.removeItem(at: file) }
            }
        } catch { logger.notice("Optional waveform disk cache unavailable") }
    }
}
