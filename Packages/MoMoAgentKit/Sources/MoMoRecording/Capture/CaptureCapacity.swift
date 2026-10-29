import Foundation
import MoMoContracts

public struct CaptureCapacityReader: Sendable {
    private let read: @Sendable (URL) throws -> Int64

    public init(read: @escaping @Sendable (URL) throws -> Int64) { self.read = read }

    public static let live = CaptureCapacityReader { directory in
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber, bytes.int64Value >= 0 else {
            throw CaptureCapacityError.unavailable
        }
        return bytes.int64Value
    }

    public func check(at directory: URL, budget: CaptureCapacityBudget,
                      stage: CaptureCapacityStage) throws -> CaptureCapacitySnapshot {
        let available: Int64
        do { available = try read(directory) }
        catch { throw CaptureCapacityError.unavailable }
        guard available >= 0 else { throw CaptureCapacityError.unavailable }
        let snapshot = CaptureCapacitySnapshot(availableBytes: available, budget: budget, stage: stage)
        guard available >= budget.requiredBytes else { throw CaptureCapacityError.insufficient(snapshot) }
        return snapshot
    }
}

public enum CaptureCapacityStage: String, Codable, Sendable { case starting, rotating }

/// Admission allowance, not a reservation or a promise against another process consuming disk space.
public struct CaptureCapacityBudget: Codable, Equatable, Sendable {
    public let nextAudioBytes: Int64
    public let closingAndCopyBytes: Int64
    public let metadataBytes: Int64
    public var requiredBytes: Int64 { nextAudioBytes + closingAndCopyBytes + metadataBytes }

    public init(targetFrames: Int64, databasePageSize: Int64, databasePageCount: Int64) throws {
        guard (1...4_800_000).contains(targetFrames), (512...65_536).contains(databasePageSize),
              databasePageCount > 0, databasePageCount < Int64.max / databasePageSize / 128 else {
            throw CaptureCapacityError.invalidBudget
        }
        // Budget the uncompressed mono Float32 working size rather than assume a measured AAC bitrate is a bound.
        nextAudioBytes = targetFrames * Int64(MemoryLayout<Float>.size)
        closingAndCopyBytes = nextAudioBytes
        let envelopeAllowance = Int64(ManifestEnvelope.maximumManifestBytes * 2)
        // Draft replacement, sealed sidecar, working draft, manifest and envelope; one atomic replacement temporary.
        let sidecars = envelopeAllowance * 6
        // Up to one page split for each existing page, plus the new serialized metadata.
        let growthPages = (sidecars + databasePageSize - 1) / databasePageSize
        let pages = databasePageCount * 2 + growthPages
        // Intent + epoch + start diagnostic + owner + chunk + capacity stop (intent/diagnostic) + epoch end + receipt + cleanup.
        let transactions: Int64 = 9
        // SQLite WAL: 32-byte header, 24-byte frame header per database page (sqlite.org/fileformat2.html).
        metadataBytes = sidecars + growthPages * databasePageSize + transactions * (32 + pages * (databasePageSize + 24))
    }
}

public struct CaptureCapacitySnapshot: Codable, Equatable, Sendable {
    public let availableBytes: Int64
    public let budget: CaptureCapacityBudget
    public let stage: CaptureCapacityStage
}

public enum CaptureCapacityError: Error, Equatable, Sendable, LocalizedError {
    case insufficient(CaptureCapacitySnapshot), unavailable, invalidBudget

    public var errorDescription: String? {
        switch self {
        case .insufficient: String(localized: "手表空间不足，录音已停止。已保存且未确认的录音会继续保留。", bundle: AppLanguage.resourceBundle)
        case .unavailable: String(localized: "无法读取手表可用空间，录音已停止。", bundle: AppLanguage.resourceBundle)
        case .invalidBudget: String(localized: "无法计算录音空间预算，录音已停止。", bundle: AppLanguage.resourceBundle)
        }
    }
}
