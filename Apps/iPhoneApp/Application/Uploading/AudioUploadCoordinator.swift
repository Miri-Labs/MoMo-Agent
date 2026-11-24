import AVFoundation
import CryptoKit
import Foundation
import Observation
import OSLog
import UIKit
import MoMoAgentClient
import MoMoArchive

/// Mac-as-Backend audio relay coordinator on iPhone.
///
/// iPhone no longer runs any local ASR, diarization, or speaker embedding models.
/// Instead, whenever Apple Watch or Bluetooth Earphone audio chunks arrive in `ArchiveStore`,
/// this coordinator verifies local `manifest.audioSHA256` integrity, auto-transcodes oversized
/// chunks (> 460 KB) into cached deterministic 16 kHz mono AAC so every upload stays below
/// Relay's 512 KB cap and retries remain bit-identical, validates Mac's returned receipt
/// `(chunkId, sha256)` before allowing local Retention pruning, isolates poison chunks with
/// exponential backoff, serializes transcript syncs with persisted source revisions, and
/// collaborates cleanly under `PhoneContextDelivery`'s single OS background budget.
@MainActor @Observable
final class AudioUploadCoordinator {
    enum UploadError: LocalizedError {
        case corruptedLocalAudio(expectedSHA: String, actualSHA: String)
        case transcodeFailed(String)
        case receiptIntegrityMismatch(expectedChunkID: String, expectedSHA: String)
        case transientDeliveryIncomplete(String)

        var errorDescription: String? {
            switch self {
            case .corruptedLocalAudio:
                return "本地录音原音校验异常，暂不上传以防覆盖。"
            case .transcodeFailed(let reason):
                return "音频压缩转码失败：\(reason)"
            case .receiptIntegrityMismatch:
                return "Mac 音频上传回执校验不一致，保留本地原音等待重试。"
            case .transientDeliveryIncomplete(let msg):
                return msg
            }
        }
    }

    private static let relaySafeMaxBytes = 460 * 1024
    private static let relayHardCapBytes = 512 * 1024

    private(set) var pendingCount = 0
    private(set) var uploadedCount = 0
    private(set) var failedCount = 0
    private(set) var permanentFailedCount = 0
    private(set) var isUploading = false
    private(set) var lastUploadedAt: Date?
    private(set) var lastSyncedTranscriptsAt: Date?
    private(set) var macStatus: MacTranscriptionStatus?
    private(set) var lastError: String?

    /// Synchronous optimistic flag set the moment a new chunk arrives so `PhoneContextDelivery`
    /// sees `needsDelivery() == true` before the async count query completes.
    @ObservationIgnored private var pendingUploadHint = false

    var hasPendingWork: Bool {
        pendingUploadHint || pendingCount > 0 || failedCount > 0
    }

    @ObservationIgnored private let archive: ArchiveStore
    @ObservationIgnored private let dataClientProvider: @MainActor () -> AgentClient?
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let onTranscriptsUpdated: @MainActor () async -> Void
    @ObservationIgnored private let onAuthenticationRequired: @MainActor (Error) -> Void
    @ObservationIgnored private var uploadTask: Task<Error?, Never>?
    @ObservationIgnored private var uploadTaskToken = UUID()
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var retryScheduled = false
    @ObservationIgnored private var knownSourceRevisions: [String: String] = [:]
    @ObservationIgnored private var hydratedSourceRevisions = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.momoagent.ios", category: "MacAudioRelay")

    init(
        archive: ArchiveStore,
        deviceID: UUID,
        dataClientProvider: @escaping @MainActor () -> AgentClient?,
        onTranscriptsUpdated: @escaping @MainActor () async -> Void = {},
        onAuthenticationRequired: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        self.archive = archive
        self.deviceID = deviceID
        self.dataClientProvider = dataClientProvider
        self.onTranscriptsUpdated = onTranscriptsUpdated
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    func notePendingUploadArrived() {
        pendingUploadHint = true
    }

    func foreground() {
        requestUpload()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshCounts()
                // Only wake upload loop when a client is contactable and at least one due chunk exists
                // (avoids 8s background-task / spinner churn when chunks are backed off or auth failed).
                if self.dataClientProvider() != nil,
                   let due = try? await self.archive.pendingMacAudioUploads(limit: 1),
                   !due.isEmpty {
                    self.requestUpload()
                }
                await self.syncRemoteTranscriptsFromMac()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func background() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Invoked when `NWPathMonitor` reports a newly satisfied network path so transient backoff
    /// timers clear immediately and pending chunks resume without waiting for the next timer tick.
    func handleNetworkPathRecovered() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.archive.resetTransientMacAudioUploadBackoff()
            await self.refreshCounts()
            if self.pendingCount > 0 || self.failedCount > 0 {
                self.requestUpload()
            }
        }
    }

    func cancelUpload() {
        retryScheduled = false
        uploadTask?.cancel()
    }

    func requestUpload() {
        guard uploadTask == nil else {
            retryScheduled = true
            return
        }
        let token = UUID()
        uploadTaskToken = token
        uploadTask = Task { [weak self] in
            guard let self else { return nil }
            defer {
                if self.uploadTaskToken == token {
                    self.uploadTask = nil
                    if self.retryScheduled, !Task.isCancelled {
                        self.retryScheduled = false
                        self.requestUpload()
                    }
                }
            }
            return await self.runSerializedUploadLoop(ownsBackgroundGrant: true, requestTimeout: 45, syncAfterUpload: true)
        }
    }

    /// Awaits any in-flight upload pass or starts a single serialized pass (prevents concurrent double-upload).
    func drainUploadQueue() async {
        if let existing = uploadTask {
            retryScheduled = true
            _ = await existing.value
            while let followUp = uploadTask {
                _ = await followUp.value
            }
            return
        }
        requestUpload()
        while let current = uploadTask {
            _ = await current.value
        }
    }

    /// Background delivery entry point owned by `PhoneContextDelivery` (single 25s OS background grant).
    /// Strictly serializes against any in-flight upload without spawning concurrent passes, uses a
    /// bounded 20s per-request timeout, skips full history transcript pulls during the upload pass,
    /// and throws on transient/auth failures so `PhoneContextDelivery` reports `success = false`
    /// and keeps `BGProcessingTask` scheduled.
    func deliverInBackgroundPass() async throws {
        // Prevent any active foreground pass's defer from spawning an extra foreground grant behind our back.
        retryScheduled = false
        while let existing = uploadTask {
            let err = await existing.value
            try Task.checkCancellation()
            if let err { throw err }
        }
        let token = UUID()
        uploadTaskToken = token
        let task = Task<Error?, Never> { [weak self] in
            guard let self else { return CancellationError() }
            defer {
                if self.uploadTaskToken == token {
                    self.uploadTask = nil
                }
            }
            var lastFailure: Error?
            repeat {
                self.retryScheduled = false
                if let err = await self.runSerializedUploadLoop(ownsBackgroundGrant: false, requestTimeout: 20, syncAfterUpload: false) {
                    lastFailure = err
                    break
                }
            } while self.retryScheduled && !Task.isCancelled
            return lastFailure
        }
        uploadTask = task
        let failure = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        if let failure {
            throw failure
        }
    }

    func refreshCounts() async {
        if let counts = try? await archive.macAudioUploadCounts() {
            pendingCount = counts.pending
            uploadedCount = counts.uploaded
            failedCount = counts.failed
            permanentFailedCount = counts.permanentFailed
            if counts.pending == 0 && counts.failed == 0 {
                pendingUploadHint = false
            }
        }
    }

    private func runSerializedUploadLoop(
        ownsBackgroundGrant: Bool,
        requestTimeout: TimeInterval,
        syncAfterUpload: Bool
    ) async -> Error? {
        await refreshCounts()
        guard let client = dataClientProvider() else {
            return pendingCount > 0 || failedCount > 0
                ? UploadError.transientDeliveryIncomplete("尚未连接 Mac")
                : nil
        }

        final class BGGrantBox: @unchecked Sendable {
            private let lock = NSLock()
            private var id: UIBackgroundTaskIdentifier = .invalid
            private var workTask: Task<Error?, Never>?

            func set(id: UIBackgroundTaskIdentifier, workTask: Task<Error?, Never>?) {
                lock.withLock {
                    self.id = id
                    self.workTask = workTask
                }
            }

            func takeID() -> UIBackgroundTaskIdentifier {
                lock.withLock {
                    let current = id
                    id = .invalid
                    workTask = nil
                    return current
                }
            }

            func endIfNeeded() {
                let (current, task) = lock.withLock { () -> (UIBackgroundTaskIdentifier, Task<Error?, Never>?) in
                    let c = id
                    id = .invalid
                    let t = workTask
                    workTask = nil
                    return (c, t)
                }
                task?.cancel()
                if current != .invalid {
                    Task { @MainActor in
                        UIApplication.shared.endBackgroundTask(current)
                    }
                }
            }
        }

        var grantBox: BGGrantBox?
        if ownsBackgroundGrant {
            let box = BGGrantBox()
            let bgID = UIApplication.shared.beginBackgroundTask(withName: "Upload audio chunks to Mac") {
                box.endIfNeeded()
            }
            box.set(id: bgID, workTask: uploadTask)
            grantBox = box
        }
        defer {
            if let current = grantBox?.takeID(), current != .invalid {
                UIApplication.shared.endBackgroundTask(current)
            }
        }

        isUploading = true
        defer { isUploading = false }

        var uploadedAny = false
        var firstBlockingError: Error?
        var attemptedInPass = Set<UUID>()

        while !Task.isCancelled {
            guard let pending = try? await archive.pendingMacAudioUploads(limit: 8) else { break }
            let batch = pending.filter { !attemptedInPass.contains($0.chunkID) }
            if batch.isEmpty { break }

            var hitTransportOutage = false
            for chunk in batch {
                if Task.isCancelled { break }
                attemptedInPass.insert(chunk.chunkID)
                do {
                    let prepared = try await Self.prepareWirePayload(for: chunk)
                    let meta = AudioChunkUploadMeta(
                        chunkId: chunk.chunkID.uuidString.lowercased(),
                        libraryId: archive.libraryInstanceID,
                        sessionId: chunk.sessionID,
                        deviceId: self.deviceID,
                        chunkSeq: chunk.chunkSeq,
                        recordedAt: chunk.recordedAt,
                        durationSec: chunk.durationSec,
                        timezoneOffset: chunk.timezoneOffset,
                        sourceKind: chunk.sourceKind,
                        codec: prepared.codec,
                        sampleRate: prepared.sampleRate,
                        sha256: prepared.sha256
                    )
                    let receipt = try await client.uploadAudioChunk(
                        meta: meta,
                        audioData: prepared.data,
                        timeout: requestTimeout
                    )
                    // Strict integrity check (matching Watch<->iPhone ArchiveStore standards) before allowing Retention to prune local audio.
                    let expectedChunkID = chunk.chunkID.uuidString.lowercased()
                    guard receipt.accepted,
                          receipt.chunkId.lowercased() == expectedChunkID,
                          receipt.sha256.lowercased() == prepared.sha256.lowercased() else {
                        throw UploadError.receiptIntegrityMismatch(
                            expectedChunkID: expectedChunkID,
                            expectedSHA: prepared.sha256
                        )
                    }
                    try await archive.markMacAudioChunkUploaded(
                        chunkID: chunk.chunkID,
                        remoteSHA256: receipt.sha256,
                        remoteSourceID: receipt.sourceId
                    )
                    Self.removeCachedTranscodeIfPresent(for: chunk)
                    lastUploadedAt = Date()
                    lastError = nil
                    uploadedAny = true
                } catch {
                    if Task.isCancelled { break }
                    let kind = Self.classifyUploadError(error)
                    logger.warning("Failed uploading chunk \(chunk.chunkID.uuidString, privacy: .public) [\(String(describing: kind), privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                    lastError = error.localizedDescription

                    switch kind {
                    case .unauthorized:
                        try? await archive.markMacAudioChunkFailed(
                            chunkID: chunk.chunkID,
                            error: error.localizedDescription,
                            permanent: false,
                            retryDelay: 60
                        )
                        onAuthenticationRequired(error)
                        firstBlockingError = firstBlockingError ?? error
                        hitTransportOutage = true
                    case .permanentChunkError:
                        // Isolate poison/missing/corrupt chunk permanently so older healthy chunks are NEVER head-of-line blocked.
                        try? await archive.markMacAudioChunkFailed(
                            chunkID: chunk.chunkID,
                            error: error.localizedDescription,
                            permanent: true
                        )
                        Self.removeCachedTranscodeIfPresent(for: chunk)
                        continue
                    case .transientChunkError:
                        // Back off just this chunk (e.g. receipt/in-transit SHA mismatch) and keep advancing healthy chunks.
                        try? await archive.markMacAudioChunkFailed(
                            chunkID: chunk.chunkID,
                            error: error.localizedDescription,
                            permanent: false
                        )
                        firstBlockingError = firstBlockingError ?? error
                        continue
                    case .transportOutage:
                        try? await archive.markMacAudioChunkFailed(
                            chunkID: chunk.chunkID,
                            error: error.localizedDescription,
                            permanent: false
                        )
                        firstBlockingError = firstBlockingError ?? error
                        hitTransportOutage = true
                    }
                    if hitTransportOutage { break }
                }
            }
            await refreshCounts()
            if hitTransportOutage { break }
        }

        await refreshCounts()
        if syncAfterUpload && uploadedAny && !Task.isCancelled {
            await syncRemoteTranscriptsFromMac()
        }
        return firstBlockingError
    }

    private enum UploadFailureClass {
        case unauthorized
        case permanentChunkError
        case transientChunkError
        case transportOutage
    }

    private static func classifyUploadError(_ error: Error) -> UploadFailureClass {
        if case let relayError as RelayError = error {
            switch relayError {
            case .authentication, .invalidConfiguration:
                return .unauthorized
            case .requestTooLarge:
                return .permanentChunkError
            case .unavailable, .protocolFailure:
                return .transportOutage
            }
        }
        if case AgentClientError.http(let status, _, let message, _) = error {
            switch status {
            case 401, 403:
                return .unauthorized
            case 400:
                // Transient in-transit SHA mismatch is retryable; structural validation errors are permanent.
                let msg = (message ?? "").lowercased()
                if msg.contains("sha-256 mismatch") {
                    return .transientChunkError
                }
                return .permanentChunkError
            case 404, 413, 415, 422:
                return .permanentChunkError
            case 408, 429, 500...599:
                return .transportOutage
            default:
                return .transientChunkError
            }
        }
        if case UploadError.corruptedLocalAudio = error {
            return .permanentChunkError
        }
        if case UploadError.receiptIntegrityMismatch = error {
            return .transientChunkError
        }
        if case UploadError.transcodeFailed = error {
            return .transientChunkError
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError) {
            return .permanentChunkError
        }
        return .transportOutage
    }

    private struct PreparedWirePayload: Sendable {
        let data: Data
        let sha256: String
        let codec: String
        let sampleRate: Int
    }

    private static func cachedTranscodeURL(for chunk: PendingMacAudioChunk) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoRelayAACCache", isDirectory: true)
        return dir.appendingPathComponent("\(chunk.chunkID.uuidString.lowercased())_\(chunk.audioSHA256.prefix(16)).m4a")
    }

    private static func removeCachedTranscodeIfPresent(for chunk: PendingMacAudioChunk) {
        try? FileManager.default.removeItem(at: cachedTranscodeURL(for: chunk))
    }

    /// Reads local audio chunk, strictly verifies its bytes against immutable `chunk.audioSHA256`,
    /// and transcodes oversized chunks (> 460 KB) into a deterministically cached 16 kHz mono AAC
    /// file so uploads fit below Relay's 512 KB cap and retries remain bit-identical across attempts.
    private static func prepareWirePayload(for chunk: PendingMacAudioChunk) async throws -> PreparedWirePayload {
        let rawData = try Data(contentsOf: chunk.audioURL, options: .mappedIfSafe)
        let localSHA = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        let expectedLocalSHA = chunk.audioSHA256.lowercased()
        guard expectedLocalSHA.isEmpty || localSHA == expectedLocalSHA else {
            throw UploadError.corruptedLocalAudio(expectedSHA: expectedLocalSHA, actualSHA: localSHA)
        }

        if rawData.count > relaySafeMaxBytes {
            let cacheURL = cachedTranscodeURL(for: chunk)
            if let existing = try? Data(contentsOf: cacheURL),
               !existing.isEmpty,
               existing.count <= relayHardCapBytes {
                let sha = SHA256.hash(data: existing).map { String(format: "%02x", $0) }.joined()
                return PreparedWirePayload(data: existing, sha256: sha, codec: "aac", sampleRate: 16_000)
            }
            let transcoded = try await transcodeToRelaySafeAAC(sourceURL: chunk.audioURL, cacheURL: cacheURL)
            guard !transcoded.isEmpty, transcoded.count <= relayHardCapBytes else {
                try? FileManager.default.removeItem(at: cacheURL)
                throw UploadError.transcodeFailed("转码产物大小超限 (\(transcoded.count) bytes)")
            }
            let sha = SHA256.hash(data: transcoded).map { String(format: "%02x", $0) }.joined()
            return PreparedWirePayload(data: transcoded, sha256: sha, codec: "aac", sampleRate: 16_000)
        }

        return PreparedWirePayload(data: rawData, sha256: localSHA, codec: chunk.codec, sampleRate: chunk.sampleRate)
    }

    private static func transcodeToRelaySafeAAC(sourceURL: URL, cacheURL: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let inputFile = try AVAudioFile(forReading: sourceURL)
            let inputFormat = inputFile.processingFormat
            guard let targetPCM = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw UploadError.transcodeFailed("无法创建 16 kHz PCM 格式")
            }

            let cacheDir = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let tmpURL = cacheDir.appendingPathComponent(".tmp-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
            ]
            do {
                let outputFile = try AVAudioFile(
                    forWriting: tmpURL,
                    settings: aacSettings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                let needsConvert = inputFormat.sampleRate != targetPCM.sampleRate
                    || inputFormat.channelCount != targetPCM.channelCount
                    || inputFormat.commonFormat != targetPCM.commonFormat
                let converter: AVAudioConverter?
                if needsConvert {
                    guard let conv = AVAudioConverter(from: inputFormat, to: targetPCM) else {
                        throw UploadError.transcodeFailed("不支持的音频格式转换")
                    }
                    converter = conv
                } else {
                    converter = nil
                }

                let readCapacity: AVAudioFrameCount = 16_384
                guard let readBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readCapacity) else {
                    throw UploadError.transcodeFailed("无法分配音频读缓冲")
                }

                if let converter {
                    let ratio = targetPCM.sampleRate / max(1.0, inputFormat.sampleRate)
                    let outCapacity = AVAudioFrameCount(ceil(Double(readCapacity) * ratio)) + 2048
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetPCM, frameCapacity: outCapacity) else {
                        throw UploadError.transcodeFailed("无法分配音频写缓冲")
                    }
                    var reachedEOF = false
                    var readErr: Error?
                    while true {
                        outBuf.frameLength = 0
                        var convertErr: NSError?
                        let status = converter.convert(to: outBuf, error: &convertErr) { _, outStatus in
                            if reachedEOF {
                                outStatus.pointee = .endOfStream
                                return nil
                            }
                            if inputFile.framePosition >= inputFile.length {
                                reachedEOF = true
                                outStatus.pointee = .endOfStream
                                return nil
                            }
                            readBuf.frameLength = 0
                            do {
                                try inputFile.read(into: readBuf, frameCount: readCapacity)
                                if readBuf.frameLength == 0 {
                                    reachedEOF = true
                                    outStatus.pointee = .endOfStream
                                    return nil
                                }
                                outStatus.pointee = .haveData
                                return readBuf
                            } catch {
                                readErr = error
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                        }
                        if let readErr {
                            throw UploadError.transcodeFailed(readErr.localizedDescription)
                        }
                        if status == .error {
                            throw UploadError.transcodeFailed(convertErr?.localizedDescription ?? "AVAudioConverter returned .error")
                        }
                        if outBuf.frameLength > 0 {
                            try outputFile.write(from: outBuf)
                        }
                        if status == .endOfStream { break }
                        if status == .inputRanDry && reachedEOF { break }
                    }
                } else {
                    while inputFile.framePosition < inputFile.length {
                        readBuf.frameLength = 0
                        try inputFile.read(into: readBuf, frameCount: readCapacity)
                        if readBuf.frameLength == 0 { break }
                        try outputFile.write(from: readBuf)
                    }
                }
            }

            let data = try Data(contentsOf: tmpURL)
            guard !data.isEmpty else {
                throw UploadError.transcodeFailed("AAC 编码输出为空")
            }
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try? FileManager.default.removeItem(at: cacheURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: cacheURL)
            return data
        }.value
    }

    /// Pulls Mac-authoritative MOSS + ReDimNet2+ transcripts and chunk statuses into local iPhone SQLite cache.
    /// Strictly serialized across callers so concurrent syncs never race on `cacheMacRemoteTranscript` version numbers.
    func syncRemoteTranscriptsFromMac(force: Bool = false) async {
        if let existing = syncTask {
            await existing.value
            if !force { return }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            await self.runSerializedTranscriptSync(force: force)
        }
        syncTask = task
        await task.value
    }

    private func runSerializedTranscriptSync(force: Bool) async {
        guard let client = dataClientProvider() else { return }
        if !hydratedSourceRevisions {
            if let persisted = try? await archive.macSyncedSourceRevisions() {
                knownSourceRevisions = persisted
            }
            hydratedSourceRevisions = true
        }
        var changed = false
        do {
            // Probe reachability BEFORE clearing persisted revisions on `force: true` so offline refreshes
            // do not wipe local revision state.
            let status = try await client.transcriptionStatus()
            macStatus = status
            if force {
                knownSourceRevisions.removeAll()
                try? await archive.clearMacSyncedSourceRevisions()
            }

            // 1. Paginate ALL unsettled uploaded chunks (`done` / `silent` / `failed`, plus re-queue if Mac reports `uploaded: false`).
            var unsettledOffset = 0
            var requeuedAny = false
            for _ in 0..<16 {
                guard let unsettled = try? await archive.uploadedUnsettledMacAudioChunkIDs(limit: 64, offset: unsettledOffset),
                      !unsettled.isEmpty else { break }
                let batch = try await client.audioChunkBatchStatus(chunkIDs: unsettled.map { $0.uuidString.lowercased() })
                var statusUpdates: [UUID: String] = [:]
                var missingOnMac: [UUID] = []
                for cid in unsettled {
                    let key = cid.uuidString.lowercased()
                    guard let entry = batch.statuses[key] else { continue }
                    if !entry.uploaded {
                        missingOnMac.append(cid)
                    } else if let txState = entry.transcriptionStatus,
                              txState == "done" || txState == "silent" || txState == "failed" {
                        statusUpdates[cid] = txState
                    }
                }
                var settledThisPage = 0
                if !statusUpdates.isEmpty {
                    let count = (try? await archive.markMacAudioChunksStatus(statusUpdates)) ?? 0
                    settledThisPage += count
                    if count > 0 { changed = true }
                }
                if !missingOnMac.isEmpty {
                    let count = (try? await archive.requeueMissingRemoteMacAudioChunks(missingOnMac)) ?? 0
                    settledThisPage += count
                    if count > 0 {
                        requeuedAny = true
                        changed = true
                    }
                }
                if unsettled.count < 64 { break }
                // Advance past chunks still genuinely pending/processing on Mac.
                unsettledOffset += max(0, unsettled.count - settledThisPage)
            }
            if requeuedAny {
                await refreshCounts()
                requestUpload()
            }

            // 2. Paginate ALL Mac sources for this library, isolating per-source errors (e.g. HTTP 409 mid-update).
            let libPrefix = archive.libraryInstanceID.uuidString.lowercased() + "/"
            var cursor: String? = nil
            var seenCursors = Set<String>()
            repeat {
                let page = try await client.sources(after: cursor, summarize: false, limit: 60)
                for src in page.items where src.id.hasPrefix(libPrefix) {
                    if !force && knownSourceRevisions[src.id] == src.revision { continue }
                    let sessionStr = String(src.id.dropFirst(libPrefix.count))
                    guard let sessionUUID = UUID(uuidString: sessionStr) else { continue }

                    do {
                        var allRawSpans: [SourceTextSpan] = []
                        var seenSpanIDs = Set<String>()
                        var textOffset = 0
                        var pageGuard = 0
                        var completedAllPages = false
                        while pageGuard < 512 {
                            pageGuard += 1
                            let textPage = try await client.sourceText(src, offset: textOffset, limit: 24_000)
                            if let batchSpans = textPage.spans {
                                for sp in batchSpans where seenSpanIDs.insert(sp.id).inserted {
                                    allRawSpans.append(sp)
                                }
                            }
                            if let next = textPage.nextOffset, next > textOffset {
                                textOffset = next
                            } else {
                                completedAllPages = true
                                break
                            }
                        }

                        // Never cache truncated pages or persist revision if pagination did not reach the end.
                        guard completedAllPages else { continue }

                        guard !allRawSpans.isEmpty else {
                            knownSourceRevisions[src.id] = src.revision
                            try? await archive.setMacSyncedSourceRevision(sourceID: src.id, revision: src.revision)
                            continue
                        }

                        let (macGen, macVer) = Self.parseRevision(src.revision)
                        let inputs: [MacRemoteTranscriptSpanInput] = allRawSpans.compactMap { sp in
                            guard let uid = UUID(uuidString: sp.id),
                                  let rawTxt = sp.text, !rawTxt.isEmpty,
                                  let rec = sp.recordedAt else { return nil }
                            let cleanTxt = Self.stripLeadingSpeakerBracket(rawTxt, speaker: sp.speaker)
                            return MacRemoteTranscriptSpanInput(
                                id: uid,
                                text: cleanTxt,
                                recordedAt: Date(timeIntervalSince1970: rec),
                                endAt: sp.endAt.map { Date(timeIntervalSince1970: $0) },
                                speaker: sp.speaker,
                                isOwner: sp.isOwner,
                                timezoneOffset: sp.timezoneOffset
                            )
                        }
                        if !inputs.isEmpty {
                            try await archive.cacheMacRemoteTranscript(
                                sessionID: sessionUUID,
                                spans: inputs,
                                macGeneration: macGen,
                                macVersion: macVer
                            )
                            knownSourceRevisions[src.id] = src.revision
                            try? await archive.setMacSyncedSourceRevision(sourceID: src.id, revision: src.revision)
                            changed = true
                        }
                    } catch {
                        if case AgentClientError.http(401, _, _, _) = error {
                            throw error
                        }
                        // Isolate per-source HTTP 409 (active recording updated mid-pagination) so remaining sources still sync.
                        logger.debug("Skipped source \(src.id, privacy: .public) during sync: \(error.localizedDescription, privacy: .public)")
                        continue
                    }
                }
                if let next = page.nextCursor, seenCursors.insert(next).inserted {
                    cursor = next
                } else {
                    cursor = nil
                }
            } while cursor != nil

            lastSyncedTranscriptsAt = Date()
        } catch {
            if case AgentClientError.http(401, _, _, _) = error {
                onAuthenticationRequired(error)
            }
            logger.debug("Remote transcript sync skipped: \(error.localizedDescription, privacy: .public)")
        }

        if changed {
            await onTranscriptsUpdated()
        }
    }

    private static func parseRevision(_ revision: String) -> (Int64?, Int64?) {
        let parts = revision.split(separator: ":")
        guard parts.count >= 2, let g = Int64(parts[0]), let v = Int64(parts[1]) else {
            return (nil, nil)
        }
        return (g, v)
    }

    private static func stripLeadingSpeakerBracket(_ text: String, speaker: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return trimmed }
        let tag = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        if let speaker, !speaker.isEmpty, tag == speaker {
            return String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}
