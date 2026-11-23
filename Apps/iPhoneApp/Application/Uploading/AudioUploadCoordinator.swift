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
/// this coordinator uploads each 60s AAC chunk (~180 KB) over HTTPS/Tailscale/Relay to Mac's
/// `POST /context/v1/audio/chunks` (SHA-256 verified), polls Mac's transcription status, and
/// caches Mac-authoritative MOSS + ReDimNet2+ transcripts back into local iPhone SQLite so
/// Timeline & RecordingDetail work seamlessly online and offline.
@MainActor @Observable
final class AudioUploadCoordinator {
    private(set) var pendingCount = 0
    private(set) var uploadedCount = 0
    private(set) var failedCount = 0
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
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var retryScheduled = false
    @ObservationIgnored private var knownSourceRevisions: [String: String] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "com.momoagent.ios", category: "MacAudioRelay")

    init(
        archive: ArchiveStore,
        deviceID: UUID,
        dataClientProvider: @escaping @MainActor () -> AgentClient?,
        onTranscriptsUpdated: @escaping @MainActor () async -> Void = {}
    ) {
        self.archive = archive
        self.deviceID = deviceID
        self.dataClientProvider = dataClientProvider
        self.onTranscriptsUpdated = onTranscriptsUpdated
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
                await self.syncRemoteTranscriptsFromMac()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func background() {
        pollTask?.cancel()
        pollTask = nil
    }

    func requestUpload() {
        guard uploadTask == nil else {
            retryScheduled = true
            return
        }
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.uploadTask = nil
                if self.retryScheduled {
                    self.retryScheduled = false
                    self.requestUpload()
                }
            }
            await self.runSerializedUploadLoop()
        }
    }

    /// Awaits any in-flight upload pass or starts a single serialized pass (prevents concurrent double-upload).
    func drainUploadQueue() async {
        if let existing = uploadTask {
            retryScheduled = true
            await existing.value
            if let followUp = uploadTask {
                await followUp.value
            }
            return
        }
        requestUpload()
        if let current = uploadTask {
            await current.value
        }
    }

    func refreshCounts() async {
        if let counts = try? await archive.macAudioUploadCounts() {
            pendingCount = counts.pending
            uploadedCount = counts.uploaded
            failedCount = counts.failed
            if counts.pending == 0 && counts.failed == 0 {
                pendingUploadHint = false
            }
        }
    }

    private func runSerializedUploadLoop() async {
        await refreshCounts()
        guard let client = dataClientProvider() else { return }

        final class BGGrantBox: @unchecked Sendable {
            private let lock = NSLock()
            private var id: UIBackgroundTaskIdentifier = .invalid
            private var workTask: Task<Void, Never>?

            func set(id: UIBackgroundTaskIdentifier, workTask: Task<Void, Never>?) {
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
                let (current, task) = lock.withLock { () -> (UIBackgroundTaskIdentifier, Task<Void, Never>?) in
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
        let grantBox = BGGrantBox()
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "Upload audio chunks to Mac") {
            grantBox.endIfNeeded()
        }
        grantBox.set(id: bgID, workTask: uploadTask)
        defer {
            let current = grantBox.takeID()
            if current != .invalid {
                UIApplication.shared.endBackgroundTask(current)
            }
        }

        isUploading = true
        defer { isUploading = false }

        var uploadedAny = false
        while !Task.isCancelled {
            guard let pending = try? await archive.pendingMacAudioUploads(limit: 8), !pending.isEmpty else {
                pendingUploadHint = false
                break
            }
            var madeProgress = false
            for chunk in pending {
                if Task.isCancelled { break }
                do {
                    let audioData = try Data(contentsOf: chunk.audioURL, options: .mappedIfSafe)
                    // Use iPhone's `self.deviceID` (matching `PhoneContextSync`) so source ownership stays consistent.
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
                        codec: chunk.codec,
                        sampleRate: chunk.sampleRate,
                        sha256: chunk.audioSHA256
                    )
                    let receipt = try await client.uploadAudioChunk(meta: meta, audioData: audioData)
                    if receipt.accepted {
                        try await archive.markMacAudioChunkUploaded(
                            chunkID: chunk.chunkID,
                            remoteSHA256: receipt.sha256,
                            remoteSourceID: receipt.sourceId
                        )
                        lastUploadedAt = Date()
                        lastError = nil
                        uploadedAny = true
                        madeProgress = true
                    }
                } catch {
                    if Task.isCancelled { break }
                    logger.warning("Failed uploading chunk \(chunk.chunkID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    try? await archive.markMacAudioChunkFailed(chunkID: chunk.chunkID, error: error.localizedDescription)
                    lastError = error.localizedDescription
                    break
                }
            }
            await refreshCounts()
            if !madeProgress { break }
        }

        if uploadedAny {
            await syncRemoteTranscriptsFromMac()
        }
    }

    /// Pulls Mac-authoritative MOSS + ReDimNet2+ transcripts and chunk statuses into local iPhone SQLite cache.
    func syncRemoteTranscriptsFromMac(force: Bool = false) async {
        guard let client = dataClientProvider() else { return }
        if force {
            knownSourceRevisions.removeAll()
        }
        do {
            let status = try await client.transcriptionStatus()
            macStatus = status
            var changed = false

            // 1. Reconcile Mac chunk statuses (`done` / `silent` / `failed`) so Timeline settles cleanly
            if let unsettled = try? await archive.uploadedUnsettledMacAudioChunkIDs(limit: 64), !unsettled.isEmpty {
                let batch = try await client.audioChunkBatchStatus(chunkIDs: unsettled.map { $0.uuidString.lowercased() })
                var statusUpdates: [UUID: String] = [:]
                for cid in unsettled {
                    let key = cid.uuidString.lowercased()
                    if let entry = batch.statuses[key], entry.uploaded, let txState = entry.transcriptionStatus {
                        if txState == "done" || txState == "silent" || txState == "failed" {
                            statusUpdates[cid] = txState
                        }
                    }
                }
                if !statusUpdates.isEmpty {
                    let count = (try? await archive.markMacAudioChunksStatus(statusUpdates)) ?? 0
                    if count > 0 { changed = true }
                }
            }

            // 2. Paginate ALL Mac sources for this library and pull every span page completely
            let libPrefix = archive.libraryInstanceID.uuidString.lowercased() + "/"
            var cursor: String? = nil
            var seenCursors = Set<String>()
            repeat {
                let page = try await client.sources(after: cursor, summarize: false, limit: 60)
                for src in page.items where src.id.hasPrefix(libPrefix) {
                    if !force && knownSourceRevisions[src.id] == src.revision { continue }
                    let sessionStr = String(src.id.dropFirst(libPrefix.count))
                    guard let sessionUUID = UUID(uuidString: sessionStr) else { continue }

                    var allRawSpans: [SourceTextSpan] = []
                    var seenSpanIDs = Set<String>()
                    var textOffset = 0
                    var pageGuard = 0
                    while pageGuard < 64 {
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
                            break
                        }
                    }

                    guard !allRawSpans.isEmpty else {
                        knownSourceRevisions[src.id] = src.revision
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
                        changed = true
                    }
                }
                if let next = page.nextCursor, seenCursors.insert(next).inserted {
                    cursor = next
                } else {
                    cursor = nil
                }
            } while cursor != nil

            lastSyncedTranscriptsAt = Date()
            if changed {
                await onTranscriptsUpdated()
            }
        } catch {
            logger.debug("Remote transcript sync skipped: \(error.localizedDescription, privacy: .public)")
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
