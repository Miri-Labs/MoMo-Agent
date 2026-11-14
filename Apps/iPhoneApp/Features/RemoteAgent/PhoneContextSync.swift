import Foundation
import Observation
import MoMoAgentClient
import MoMoArchive

/// Phone delivers original transcripts. The Mac owns memory; the phone only caches its current view.
@MainActor @Observable
final class PhoneContextSync {
    var configurationFingerprint: String?
    let recordingSummaries: PhoneRecordingSummaries?
    private(set) var summaryStorageFailure: String?
    private(set) var memories: [ContextMemory] = []
    private(set) var lastSynced: Date?
    private(set) var failure: String?
    private(set) var sourceDeliveryFailure: String?
    private(set) var isSyncing = false
    private(set) var isUploadingSources = false
    private(set) var memoryPending = 0
    private(set) var memoryNeedsReview = 0
    private(set) var memoryReview: MemoryReviewStatus?
    private(set) var isDreamRequesting = false
    var pendingSources: Int { state.sources.values.filter { $0.receipt == nil }.count }
    var needsDelivery: Bool {
        stateNeedsPersistence || (state.lastSourcesSent == nil && state.examinedChangeRevision == nil)
            || state.sources.values.contains { $0.receipt == nil && $0.deliveryFailure == nil }
            || ((state.sourceChangeRevision ?? 0) != (state.deliveredChangeRevision ?? 0)
                && state.sourceChangeRevision != state.examinedChangeRevision)
    }
    var lastSourcesSent: Date? { state.lastSourcesSent }
    var sourceChangeRevision: Int64 { state.sourceChangeRevision ?? 0 }
    var needsIllustrationRefresh: Bool { state.illustrationRefreshPending == true }
    var hasUnfinishedIllustrationDownload: Bool { state.illustrationDownloadIncomplete == true }
    var hasLegacyChanges: Bool { !state.forget.isEmpty }
    @ObservationIgnored var onAuthenticationRequired: ((Error) -> Void)?
    @ObservationIgnored var onConnectionConfirmed: (() -> Void)?
    @ObservationIgnored private var authenticationRequired = false
    @ObservationIgnored private let archive: ArchiveStore
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let memoryFile: URL
    @ObservationIgnored private var state: State
    @ObservationIgnored private var inFlight: Task<Void, Error>?
    @ObservationIgnored private var syncRequested = false
    @ObservationIgnored private var sourceGeneration = UUID()
    @ObservationIgnored private var memoryGeneration = UUID()
    @ObservationIgnored private var memoryTask: Task<Void, Error>?
    @ObservationIgnored private var reviewTask: Task<Void, Never>?
    @ObservationIgnored private var reviewGeneration = UUID()
    @ObservationIgnored private var memoryRetry: (until: Date, error: Error)?
    @ObservationIgnored private var sourceRetry: (until: Date, error: Error)?
    @ObservationIgnored private var reviewRetry: (until: Date, error: Error)?
    @ObservationIgnored private var stateNeedsPersistence = false
    @ObservationIgnored private var polling: Task<Void, Never>?

    private struct Source: Codable {
        var envelope: SourceEnvelope
        var receipt: SourceReceipt?
        var coverage: CoverageStamp?
        var deliveryFailure: String?
    }
    private struct CoverageStamp: Codable, Equatable {
        let chunks: Int
        let transcriptionState: String
        let audioState: String
        let fingerprint: String?
    }
    private struct State: Codable {
        let libraryID: UUID
        let connection: AgentConnection
        var sources: [String: Source] = [:]
        var forget: [ForgetMemory] = []
        var memories: [ContextMemory] = []
        var lastSynced: Date?
        var lastSourcesSent: Date?
        var sourceChangeRevision: Int64?
        var deliveredChangeRevision: Int64?
        var illustrationRefreshPending: Bool?
        var illustrationDownloadIncomplete: Bool?
        var memoryBackend: String?
        var examinedChangeRevision: Int64?
    }
    private struct MemoryCache: Codable {
        let libraryID: UUID
        let instanceID: UUID
        let memories: [ContextMemory]
        let revision: Int64?
        let lastSynced: Date?
    }
    init(directory: URL, archive: ArchiveStore, deviceID: UUID, connection: AgentConnection, key: String, configuration: URLSessionConfiguration = .ephemeral, transport: (any AgentTransport)? = nil) throws {
        guard let endpoint = connection.dataURL else { throw SyncError.unavailable }
        client = try AgentClient(baseURL: endpoint, credential: key, assistantID: connection.assistantID, configuration: configuration, transport: transport)
        self.archive = archive; self.deviceID = deviceID; file = directory.appendingPathComponent("context.json")
        memoryFile = directory.appendingPathComponent("memories-cache.json")
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.libraryID == archive.libraryInstanceID, state.connection.hasSameIdentity(as: connection) else { throw SyncError.identity }
        } else { state = State(libraryID: archive.libraryInstanceID, connection: connection) }
        // Migrate the marker used by older phone builds for the same Mac notebook.
        if state.memoryBackend == "Hermes" { state.memoryBackend = "SuperAgent" }
        memories = state.memoryBackend == "SuperAgent" ? state.memories : []; lastSynced = state.memoryBackend == "SuperAgent" ? state.lastSynced : nil
        if FileManager.default.fileExists(atPath: memoryFile.path) {
            do {
                let cached = try JSONDecoder().decode(MemoryCache.self, from: Data(contentsOf: memoryFile))
                guard cached.libraryID == state.libraryID, cached.instanceID == connection.instanceID else { throw SyncError.identity }
                memories = cached.memories; lastSynced = cached.lastSynced
            } catch SyncError.identity { throw SyncError.identity }
            catch { failure = String(localized: "笔记缓存暂时无法读取，原数据已保留。") }
        }
        sourceDeliveryFailure = state.sources.values.compactMap(\.deliveryFailure).first
        do { recordingSummaries = try PhoneRecordingSummaries(directory: directory, archive: archive, connection: connection, client: client) }
        catch {
            recordingSummaries = nil
            summaryStorageFailure = String(localized: "录音总结缓存暂时无法读取，原数据已保留。")
        }
    }
    var sources: [SourceReference] {
        state.sources.values.filter { !$0.envelope.deleted }.flatMap { source in
            source.envelope.spans.compactMap { span in
                guard let session = UUID(uuidString: source.envelope.sessionId), let id = UUID(uuidString: span.id) else { return nil }
                return SourceReference(sessionID: session, spanID: id, transcriptVersion: source.envelope.version, generation: source.envelope.generation)
            }
        }
    }
    func foreground() {
        guard polling == nil, !authenticationRequired else { return }
        recordingSummaries?.foreground()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMemories()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }
    func stopPolling() {
        polling?.cancel(); polling = nil; recordingSummaries?.background()
        cancelMemoryRefresh()
    }
    func background() { stopPolling(); cancelSynchronization() }
    func refresh() async {
        do { try await synchronize() }
        catch { if AgentTransportFailure.isCancelled(error) { return } }
    }
    func markSourcesChanged() throws {
        var updated = state
        updated.sourceChangeRevision = (updated.sourceChangeRevision ?? 0) + 1
        updated.illustrationRefreshPending = true
        updated.illustrationDownloadIncomplete = true
        try commit(updated)
    }
    func requestIllustrationRefresh() throws {
        var updated = state; updated.illustrationRefreshPending = true
        updated.illustrationDownloadIncomplete = true
        try commit(updated)
    }
    func didRefreshIllustrations(enabled: Bool, sourceRevision: Int64) throws {
        var updated = state
        // Keep observing future Mac results while generation is enabled, including work not admitted yet.
        updated.illustrationRefreshPending = enabled || sourceRevision != sourceChangeRevision
        updated.illustrationDownloadIncomplete = sourceRevision != sourceChangeRevision
        try commit(updated)
    }
    func cancelSynchronization() {
        sourceGeneration = UUID(); inFlight?.cancel(); inFlight = nil; isUploadingSources = false
    }

    private func cancelMemoryRefresh() {
        memoryGeneration = UUID(); memoryTask?.cancel(); memoryTask = nil; isSyncing = false
        reviewGeneration = UUID(); reviewTask?.cancel(); reviewTask = nil
    }

    func refreshMemories() async {
        do { try await synchronizeMemories() } catch { }
    }

    func resumeAfterCredentialVerification() { authenticationRequired = false }

    private func synchronizeMemories() async throws {
        try Task.checkCancellation()
        guard !authenticationRequired else { throw CancellationError() }
        if let memoryTask, !memoryTask.isCancelled { return try await memoryTask.value }
        if let memoryRetry, memoryRetry.until > Date() { throw memoryRetry.error }
        startMemoryReview()
        let owner = UUID(); memoryGeneration = owner; isSyncing = true
        let task = Task {
            try await downloadMemories(owner: owner)
            try Task.checkCancellation()
            guard memoryGeneration == owner else { throw CancellationError() }
            failure = nil; memoryRetry = nil
        }
        memoryTask = task
        defer { if memoryGeneration == owner { memoryTask = nil; isSyncing = false } }
        do { try await task.value }
        catch {
            guard memoryGeneration == owner, !AgentTransportFailure.isCancelled(error) else { throw error }
            memoryRetry = Self.retryWindow(error)
            recordAuthenticationFailure(error)
            failure = AgentTransportFailure.isTransient(error)
                ? String(localized: "笔记暂未刷新，请稍后重试。") : error.localizedDescription
            throw error
        }
    }

    private func startMemoryReview() {
        guard reviewTask == nil else { return }
        if let reviewRetry, reviewRetry.until > Date() { return }
        let owner = UUID(); reviewGeneration = owner
        reviewTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.reviewGeneration == owner { self.reviewTask = nil } }
            await self.refreshMemoryReview(owner: owner)
        }
    }

    private func refreshMemoryReview(owner: UUID) async {
        do {
            let status = try await client.contextStatus()
            try Task.checkCancellation()
            guard reviewGeneration == owner else { return }
            try validate(status)
            onConnectionConfirmed?()
            memoryPending = status.memoryPending ?? 0; memoryNeedsReview = status.memoryNeedsReview ?? 0
            memoryReview = status.memoryReview
            reviewRetry = nil
        } catch {
            if reviewGeneration == owner, !AgentTransportFailure.isCancelled(error) {
                reviewRetry = Self.retryWindow(error)
                recordAuthenticationFailure(error)
            }
        }
    }

    private static func retryWindow(_ error: Error) -> (until: Date, error: Error)? {
        guard case AgentClientError.http(_, _, _, let delay?) = error, delay > 0 else { return nil }
        return (Date().addingTimeInterval(delay), error)
    }

    private func validate(_ status: ContextStatus) throws {
        guard status.workspaceId == state.connection.workspaceID, status.sourceSync,
              status.memoryWriter == "SuperAgent" else { throw SyncError.identity }
    }

    private func recordAuthenticationFailure(_ error: Error) {
        if case AgentClientError.http(401, _, _, _) = error {
            authenticationRequired = true; background(); onAuthenticationRequired?(error)
        }
    }

    func synchronize(includeMemories: Bool = true) async throws {
        if includeMemories {
            async let memories: Result<Void, Error> = capture { try await self.synchronizeMemories() }
            async let sources: Result<Void, Error> = capture { try await self.synchronizeSources() }
            let results = await (memories, sources)
            try results.0.get(); try results.1.get()
        } else { try await synchronizeSources() }
    }

    private func capture(_ operation: () async throws -> Void) async -> Result<Void, Error> {
        do { try await operation(); return .success(()) } catch { return .failure(error) }
    }

    func allowSourceDeliveryRetry() throws {
        var updated = state
        for id in updated.sources.keys { updated.sources[id]?.deliveryFailure = nil }
        updated.examinedChangeRevision = nil
        try commit(updated)
    }

    private func synchronizeSources() async throws {
        try Task.checkCancellation()
        guard !authenticationRequired else { throw CancellationError() }
        if let sourceRetry, sourceRetry.until > Date() { throw sourceRetry.error }
        syncRequested = true
        if let inFlight, !inFlight.isCancelled { return try await inFlight.value }
        let owner = UUID(); sourceGeneration = owner; isUploadingSources = true
        let task = Task {
            repeat {
                try Task.checkCancellation()
                syncRequested = false
                try await synchronizeArchive()
                try Task.checkCancellation()
                guard sourceGeneration == owner else { throw CancellationError() }
                sourceDeliveryFailure = state.sources.values.compactMap(\.deliveryFailure).first
                sourceRetry = nil
            } while syncRequested && !Task.isCancelled
        }
        inFlight = task
        defer { if sourceGeneration == owner { inFlight = nil; isUploadingSources = false } }
        do { try await task.value }
        catch {
            guard sourceGeneration == owner, !AgentTransportFailure.isCancelled(error) else { throw error }
            sourceDeliveryFailure = sourceFailureMessage(error)
            sourceRetry = Self.retryWindow(error)
            recordAuthenticationFailure(error)
            throw error
        }
    }
    func forget(_ memory: ContextMemory) async {
        do {
            try await client.forget(ForgetMemory(memory: memory))
            try Task.checkCancellation()
            cancelMemoryRefresh()
            if memory.kind == "person" {
                await forgetMatchingVoiceprintIfNeeded(for: memory)
            }
            try await synchronizeMemories()
            failure = nil
        } catch {
            guard !AgentTransportFailure.isCancelled(error) else { return }
            if case AgentClientError.http(401, _, _, _) = error {
                authenticationRequired = true; background(); onAuthenticationRequired?(error)
            }
            failure = AgentTransportFailure.isTransient(error)
                ? String(localized: "暂时无法连接 Mac，请稍后重试。")
                : error.localizedDescription
        }
    }

    private func forgetMatchingVoiceprintIfNeeded(for memory: ContextMemory) async {
        var candidateNames: Set<String> = []
        if let relPath = memory.path {
            let filename = (relPath as NSString).lastPathComponent
            let stem = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty { candidateNames.insert(stem) }
        }
        let firstLine = memory.text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty {
            candidateNames.insert(firstLine)
            for sep in [" — ", " - ", " · ", "（", "("] {
                if let prefix = firstLine.components(separatedBy: sep).first?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prefix.isEmpty {
                    candidateNames.insert(prefix)
                }
            }
        }
        guard !candidateNames.isEmpty,
              let profiles = try? await archive.speakerProfiles() else { return }
        for profile in profiles where !profile.isUser {
            let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidateNames.contains(trimmed) {
                try? await archive.forgetVoiceprint(personID: profile.id)
            }
        }
    }
    func triggerDream() async {
        guard !isDreamRequesting else { return }
        isDreamRequesting = true
        defer { isDreamRequesting = false }
        do {
            _ = try await client.triggerDream()
            await refreshMemories()
        } catch {
            guard !AgentTransportFailure.isCancelled(error) else { return }
            if case AgentClientError.http(401, _, _, _) = error {
                authenticationRequired = true; background(); onAuthenticationRequired?(error)
            }
            failure = AgentTransportFailure.isTransient(error)
                ? String(localized: "暂时无法连接 Mac，请稍后重试。")
                : error.localizedDescription
        }
    }
    func prepareSubmission(input: String, attachments: [AgentAttachment] = []) async throws {
        for reference in attachments.compactMap(\.recording) {
            guard reference.libraryID == archive.libraryInstanceID else { throw RemoteTaskStore.StoreError.recordingReferenceChanged }
            for selection in reference.sessions {
                let source: Source
                do {
                    let summary = try await archive.recordingSummary(sessionID: selection.sessionID)
                    source = try await stage(summary)
                } catch ArchiveError.sessionDeleted, ArchiveError.missingRecording, ArchiveError.missingTranscript {
                    throw RemoteTaskStore.StoreError.recordingReferenceChanged
                }
                let available = Set(source.envelope.spans.map(\.id))
                guard source.envelope.generation == selection.generation,
                      source.envelope.version == selection.version,
                      selection.spanIDs.allSatisfy({ available.contains($0.uuidString.lowercased()) }) else {
                    throw RemoteTaskStore.StoreError.recordingReferenceChanged
                }
                if source.receipt == nil {
                    do { try await deliver(source) }
                    catch AgentClientError.http(409, "revision_conflict", _, _) {
                        throw RemoteTaskStore.StoreError.recordingReferenceChanged
                    }
                }
            }
        }
        let expression = try NSRegularExpression(pattern: "momoagent://source/[^\\s)\\]>]+")
        for match in expression.matches(in: input, range: NSRange(input.startIndex..., in: input)) {
            guard let range = Range(match.range, in: input), let url = URLComponents(string: String(input[range])) else { throw SyncError.sourceChanged }
            let parts = url.path.split(separator: "/"), query = url.queryItems ?? []
            guard parts.count == 2, let session = UUID(uuidString: String(parts[0])), let span = UUID(uuidString: String(parts[1])),
                  let version = query.first(where: { $0.name == "version" })?.value.flatMap(Int64.init),
                  let generation = query.first(where: { $0.name == "generation" })?.value.flatMap(Int64.init) else { throw SyncError.sourceChanged }
            let recording = try await archive.recordingSummary(sessionID: session)
            let source = try await stage(recording)
            guard source.envelope.version == version, source.envelope.generation == generation,
                  source.envelope.spans.contains(where: { $0.id == span.uuidString.lowercased() }) else { throw SyncError.sourceChanged }
            try await deliver(source)
        }
    }
    private func stage(_ recording: RecordingSummary, allowEmptyInitial: Bool = true, checkpoint: Bool = true) async throws -> Source {
        let id = recording.sessionID.uuidString.lowercased()
        let coverage = CoverageStamp(chunks: recording.chunkCount, transcriptionState: recording.transcriptionState.rawValue,
            audioState: recording.audioState.rawValue, fingerprint: configurationFingerprint)
        if let saved = state.sources[id], !saved.envelope.deleted, saved.coverage == coverage,
           saved.envelope.generation == recording.generation, saved.envelope.version == recording.transcriptVersion,
           saved.envelope.pendingTranscriptionRanges?.isEmpty == true { return saved }
        let pending = try await archive.pendingTranscriptionIntervals(sessionID: recording.sessionID, configurationFingerprint: configurationFingerprint)
            .map { SourceEnvelope.PendingTranscriptionRange(start: $0.start.timeIntervalSince1970, end: $0.end.timeIntervalSince1970) }
        if var saved = state.sources[id], !saved.envelope.deleted,
           saved.envelope.generation == recording.generation, saved.envelope.version == recording.transcriptVersion {
            if saved.envelope.pendingTranscriptionRanges != pending || saved.coverage != coverage {
                if saved.envelope.pendingTranscriptionRanges != pending { saved.receipt = nil }
                saved.deliveryFailure = nil
                saved.envelope.pendingTranscriptionRanges = pending
                saved.coverage = coverage
                var updated = state; updated.sources[id] = saved; try commit(updated, persist: checkpoint)
            }
            return saved
        }
        if recording.transcriptVersion == 0, !pending.isEmpty {
            let source = Source(envelope: SourceEnvelope(library: archive.libraryInstanceID, session: recording.sessionID,
                device: deviceID, generation: recording.generation, version: 0, recordedAt: recording.recordedAt,
                spans: [], pendingTranscriptionRanges: pending), coverage: coverage)
            var updated = state; updated.sources[id] = source; try commit(updated, persist: checkpoint)
            return source
        }
        let snapshot = try await archive.transcriptSnapshot(sessionID: recording.sessionID)
        let document = snapshot.document
        if !allowEmptyInitial, state.sources[id] == nil, document.spans.isEmpty, pending.isEmpty {
            throw ArchiveError.missingTranscript(recording.sessionID)
        }
        let spans = try document.spans.map { span -> SourceEnvelope.Span in
            guard let location = snapshot.locations[span.id] else { throw SyncError.missingSourceTime }
            let text = span.speaker.map { "[\($0)] \(span.text)" } ?? span.text
            return .init(id: span.id, text: text, recordedAt: location.recordedAt, isOwner: span.attribution?.isUser)
        }
        let source = Source(envelope: SourceEnvelope(library: archive.libraryInstanceID, session: recording.sessionID, device: deviceID,
            generation: document.generation, version: document.version, recordedAt: recording.recordedAt, spans: spans,
            pendingTranscriptionRanges: pending), coverage: coverage)
        if let newer = state.sources[id], newer.envelope.generation > document.generation ||
            (newer.envelope.generation == document.generation && newer.envelope.version > document.version) { return newer }
        if let saved = state.sources[id], saved.envelope == source.envelope { return saved }
        var updated = state; updated.sources[id] = source; try commit(updated, persist: checkpoint)
        return source
    }
    private func deliver(_ source: Source, checkpoint: Bool = true) async throws {
        let receipt = try await client.syncSource(source.envelope)
        let expected = "\(source.envelope.generation):\(source.envelope.version):\(source.envelope.textSha256):\(source.envelope.deleted ? 1 : 0)"
        guard receipt.sourceId == source.envelope.sourceID, receipt.sourceRevision == expected else { throw SyncError.identity }
        var updated = state
        if updated.sources[source.envelope.sessionId]?.envelope == source.envelope {
            updated.sources[source.envelope.sessionId]?.receipt = receipt
            updated.sources[source.envelope.sessionId]?.deliveryFailure = nil
            try commit(updated, persist: checkpoint)
        }
    }
    private func sourceFailureMessage(_ error: Error) -> String {
        AgentTransportFailure.isTransient(error)
            ? String(localized: "录音资料暂未上传，请稍后重试。") : error.localizedDescription
    }

    private func synchronizeArchive() async throws {
        let status = try await client.contextStatus()
        try Task.checkCancellation(); try validate(status)
        if let error = await applySpeakerCorrections(status) { throw error }
        try await uploadSources()
    }
    private func speakerSources(session: String?, spans: [String]) async throws -> [SourceReference] {
        guard let session, let sessionID = UUID(uuidString: session), !spans.isEmpty else { throw SyncError.identity }
        let summary = try await archive.recordingSummary(sessionID: sessionID)
        return try spans.map {
            guard let id = UUID(uuidString: $0) else { throw SyncError.identity }
            return SourceReference(sessionID: sessionID, spanID: id, transcriptVersion: summary.transcriptVersion, generation: summary.generation)
        }
    }

    private func applySpeakerCorrections(_ status: ContextStatus) async -> Error? {
        var ackIDs: [String] = []
        var firstError: Error?
        for item in status.speakerExclusions ?? [] {
            do {
                if let from = item.recordedFrom {
                    try await archive.excludeSpeaker(named: item.speaker, from: Date(timeIntervalSince1970: from))
                } else {
                    let refs = try await speakerSources(session: item.sessionId, spans: item.spanIds)
                    try await archive.excludeSpeaker(named: item.speaker, sources: refs, deliveryID: item.id)
                }
                ackIDs.append(item.id)
            } catch { firstError = firstError ?? error }
        }
        if status.retireUnknownSpeaker == true {
            do { try await archive.retireLegacyUnknownSpeaker() }
            catch { firstError = firstError ?? error }
        }
        for item in status.speakerRelabels ?? [] {
            guard item.isOwner || item.newSpeaker != "身份待确认" else { continue }
            do {
                let refs = try await speakerSources(session: item.sessionId, spans: item.spanIds)
                let feedback: SpeakerFeedback = item.isOwner ? .owner : .person(item.newSpeaker)
                let scope: SpeakerFeedbackScope = item.scope == "cluster" ? .cluster : .selection
                try await archive.correctSpeakers(refs, feedback: feedback, scope: scope, deferGlobalRematch: true, deliveryID: item.id)
                ackIDs.append(item.id)
            } catch { firstError = firstError ?? error }
        }
        if !ackIDs.isEmpty {
            do {
                try await archive.projectPendingDocuments(includeUnchanged: false)
                try await client.acknowledgeSpeakerRelabels(ids: ackIDs)
            } catch { firstError = firstError ?? error }
        }
        return firstError
    }
    private func uploadSources() async throws {
        let changeRevision = state.sourceChangeRevision
        var cursor: String?
        var firstError: Error?
        var hadDeferredProjection = false
        repeat {
            try Task.checkCancellation()
            let page = try await archive.recordingsPage(limit: 100, cursor: cursor)
            for recording in page.items {
                do { _ = try await stage(recording, allowEmptyInitial: false, checkpoint: false) }
                catch ArchiveError.missingTranscript, ArchiveError.sessionDeleted { continue }
                catch ArchiveError.projectionConflict { hadDeferredProjection = true; continue }
                catch is CancellationError { throw CancellationError() }
                catch { if firstError == nil { firstError = error } }
            }
            try checkpointSources()
            cursor = page.nextCursor
        } while cursor != nil
        for id in Array(state.sources.keys).sorted() {
            guard let source = state.sources[id], !source.envelope.deleted, let sessionID = UUID(uuidString: id) else { continue }
            do { _ = try await archive.recordingSummary(sessionID: sessionID) }
            catch ArchiveError.sessionDeleted {
                guard state.sources[id]?.envelope == source.envelope else { continue }
                var updated = state; updated.sources[id] = Source(envelope: source.envelope.tombstone())
                try commit(updated, persist: false)
            }
            catch is CancellationError { throw CancellationError() }
            catch { if firstError == nil { firstError = error } }
        }
        try checkpointSources()
        let pendingIDs = state.sources.keys.sorted {
            let lhs = state.sources[$0]?.envelope.recordedAt ?? 0
            let rhs = state.sources[$1]?.envelope.recordedAt ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        var delivered = 0
        for id in pendingIDs {
            try Task.checkCancellation()
            guard let source = state.sources[id], source.receipt == nil, source.deliveryFailure == nil else { continue }
            do {
                try await deliver(source, checkpoint: false)
                delivered += 1
                if delivered % 10 == 0 { try checkpointSources() }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                if AgentTransportFailure.isCancelled(error) { throw error }
                if case AgentClientError.http(401, _, _, _) = error { try checkpointSources(); throw error }
                if AgentTransportFailure.isTransient(error) || AgentTransportFailure.isConfigurationFailure(error) {
                    try checkpointSources(); throw error
                }
                if Self.isOversizedSource(error), state.sources[id]?.envelope == source.envelope {
                    var updated = state; updated.sources[id]?.deliveryFailure = error.localizedDescription
                    try commit(updated, persist: false)
                    delivered += 1
                    if delivered % 10 == 0 { try checkpointSources() }
                    continue
                }
                if firstError == nil { firstError = error }
            }
        }
        try checkpointSources()
        if let firstError { throw firstError }
        if !hadDeferredProjection {
            var updated = state
            updated.examinedChangeRevision = changeRevision ?? 0
            if !updated.sources.values.contains(where: { $0.receipt == nil }) {
                updated.lastSourcesSent = Date()
                updated.deliveredChangeRevision = changeRevision
            }
            try commit(updated)
        }
    }
    private static func isOversizedSource(_ error: Error) -> Bool {
        if case RelayError.requestTooLarge = error { return true }
        if case AgentClientError.http(413, _, _, _) = error { return true }
        return false
    }

    private func checkpointSources() throws {
        if stateNeedsPersistence { try commit(state) }
    }

    private func downloadMemories(owner: UUID) async throws {
        // Publish only a complete, consistent snapshot. A concurrent Mac write retries on the next refresh.
        var items: [ContextMemory] = [], revision: Int64?, after: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await client.memories(after: after, revision: revision)
            try Task.checkCancellation()
            guard memoryGeneration == owner else { throw CancellationError() }
            if let revision, revision != page.revision { throw SyncError.invalidPagination }
            revision = page.revision; items += page.items; after = page.nextCursor
            if let after, !seen.insert(after).inserted { throw SyncError.invalidPagination }
        } while after != nil
        try Task.checkCancellation()
        guard memoryGeneration == owner else { throw CancellationError() }
        let cached = MemoryCache(libraryID: state.libraryID, instanceID: state.connection.instanceID,
                                 memories: items, revision: revision, lastSynced: Date())
        try JSONEncoder().encode(cached).write(to: memoryFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if memories != items { memories = items }
        lastSynced = cached.lastSynced
    }
    private func commit(_ updated: State, persist: Bool = true) throws {
        try Task.checkCancellation()
        if persist {
            // Keep the legacy notebook checkpoint for rollback; new reads use memoryFile.
            try JSONEncoder().encode(updated).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        state = updated
        stateNeedsPersistence = !persist
    }
    enum SyncError: LocalizedError {
        case unavailable, identity, missingSourceTime, sourceChanged, invalidPagination
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Mac 连接缺少资料同步地址，请更新连接信息。")
            case .identity: String(localized: "资料同步身份不一致，已保留本机资料并停止发送。")
            case .missingSourceTime: String(localized: "录音片段缺少原始时间，尚未同步。")
            case .sourceChanged: String(localized: "引用的录音稿已变化，请从转录页重新选择，任务尚未发送。")
            case .invalidPagination: String(localized: "Mac 返回了重复的记忆分页，原缓存已保留。")
            }
        }
    }
}
