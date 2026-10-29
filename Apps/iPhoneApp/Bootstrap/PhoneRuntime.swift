import Foundation
import Observation
import OSLog
import MoMoAgentClient
import MoMoArchive
import MoMoLink
import MoMoSpeech

@MainActor @Observable
final class PhoneRuntime {
    let archive: ArchiveStore
    let remoteAgent: PhoneRemoteAgent
    let playback: AudioPlaybackController
    let speechSettings: PhoneSpeechSettings
    let library: LibraryModel
    private(set) var failure: String?
    private(set) var statusFailure: String?
    private(set) var syncFailure: String?
    private(set) var refreshFailure: String?
    private(set) var audioMaintenanceFailure: String?
    private(set) var ready = false
    private(set) var transcriptionSnapshot: TranscriptionSnapshot?
    private(set) var speechFailure: String?
    private(set) var activeBatches: [TranscriptionBatch] = []
    private(set) var preparingTranscriptionContinuation = false
    private(set) var requestedTranscriptionBatchID: UUID?
    var supportsTranscriptionContinuation: Bool {
        if #available(iOS 26.0, *) { return backgroundTasks != nil && transcription != nil }
        return false
    }
    var hasTranscriptionContinuation: Bool {
        preparingTranscriptionContinuation || requestedTranscriptionBatchID != nil
            || transcriptionSnapshot?.execution?.origin == .continuedProcessing
    }
    let modelDirectory: URL?
    private(set) var modelStatus: LocalSpeechModelStatus
    @ObservationIgnored private var transcription: TranscriptionCoordinator?
    @ObservationIgnored private let receiver: PhoneReceiveCoordinator
    @ObservationIgnored private let transport: WatchConnectivityTransport?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var fileReconciliationRequested = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let speechFingerprint: String?
    @ObservationIgnored let speech: SpeechEngine?
    @ObservationIgnored private let speechPerformance: PhoneSpeechPerformance?
    @ObservationIgnored private var speechWarmup: Task<Void, Never>?
    @ObservationIgnored private var speechWarmed = false
    @ObservationIgnored private var speechWarmupRetryAt = Date.distantPast
    @ObservationIgnored private var lastAudioMaintenance: Date?
    @ObservationIgnored private var audioMaintenance: Task<Void, Never>?
    @ObservationIgnored private var audioMaintenanceRequested = false
    @ObservationIgnored private var obsoleteArtifactsRemoved = false
    @ObservationIgnored private let backgroundTasks: PhoneBackgroundTasks?
    @ObservationIgnored private var transcriptionContinuation: PhoneTranscriptionContinuation?
    @ObservationIgnored private var receivedAudioTranscription: ReceivedAudioTranscription?
    @ObservationIgnored private var resumingAutomaticTranscription = false
    @ObservationIgnored private var automaticResumeRequested = false
    @ObservationIgnored private var libraryPresentationDeferred = false
    @ObservationIgnored private var transcriptionRefresh = TranscriptionRefreshGate()
    @ObservationIgnored private let logger = Logger(subsystem: "com.momoagent.ios", category: "LibraryRefresh")
#if DEBUG
    @ObservationIgnored var uiTestConfiguration: PhoneUITestConfiguration?
#endif

    init(archive: ArchiveStore, remoteAgent: PhoneRemoteAgent, playback: AudioPlaybackController,
         receiver: PhoneReceiveCoordinator, transport: WatchConnectivityTransport?,
         speech: SpeechEngine?, speechFailure: String?, backgroundTasks: PhoneBackgroundTasks? = nil,
         modelDirectory: URL? = nil, speechPerformance: PhoneSpeechPerformance? = nil) throws {
        self.archive = archive
        self.remoteAgent = remoteAgent
        self.playback = playback
        self.receiver = receiver
        self.speechPerformance = speechPerformance
        self.transport = transport
        self.backgroundTasks = backgroundTasks
        self.modelDirectory = modelDirectory
        self.speech = speech
        speechSettings = PhoneSpeechSettings(speech: speech,
            modelDirectory: archive.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/SpeechModels"))
        modelStatus = speech == nil ? .unavailable(speechFailure ?? String(localized: "本地转写模型未配置")) : .awaitingValidation
        library = LibraryModel(archive: archive, configurationFingerprint: speech?.configurationFingerprint) { [weak remoteAgent] windows in
            try await remoteAgent?.summarizeRecordings(windows) ?? [:]
        }
        self.speechFailure = speechFailure
        speechFingerprint = speech?.configurationFingerprint
        remoteAgent.onSummariesChanged = { [weak self] in self?.library.timeline.refreshCachedSummaries() }
        if let speech {
            transcription = try TranscriptionCoordinator(archive: archive, speech: speech) { [weak self] snapshot in
                Task { @MainActor in
                    guard let self else { return }
                    let becameIdle = snapshot.phase == .idle && self.transcriptionSnapshot?.phase != .idle
                    let completedNewWindows = snapshot.completedWindows > (self.transcriptionSnapshot?.completedWindows ?? 0)
                    self.transcriptionSnapshot = snapshot
                    self.speechPerformance?.record(snapshot, foreground: self.isForeground)
                    if snapshot.completedWindows > 0 { self.modelStatus = .ready }
                    self.backgroundTasks?.update(snapshot)
                    if !self.isForeground, self.transcriptionContinuation?.isActive == true, !snapshot.nativeInFlight,
                       [.idle, .systemSuspended, .paused, .failed, .waitingForAudio, .waitingForContext, .waitingForRetry, .audioUnavailable].contains(snapshot.phase) {
                        if await self.transcription?.finishForegroundContinuationIfIdle() == true {
                            self.transcriptionContinuation?.finish()
                        }
                    }
                    let settled = !snapshot.nativeInFlight
                        && [.idle, .queued, .waitingForAudio, .waitingForContext, .waitingForRetry, .audioUnavailable, .systemSuspended, .paused, .failed].contains(snapshot.phase)
                    let refreshProgress = self.transcriptionRefresh.shouldRefresh(completedNewWindow: completedNewWindows,
                        settled: settled)
                    if self.libraryPresentationDeferred {
                        if refreshProgress {
                            if completedNewWindows || settled { self.remoteAgent.sourcesChanged() }
                            await self.receiver.publishStatus()
                        }
                        return
                    }
                    guard refreshProgress else { return }
                    await self.refreshBatches()
                    if settled {
                        await self.refresh(reconcileFiles: false)
                    } else if refreshProgress {
                        if completedNewWindows { self.remoteAgent.sourcesChanged() }
                        await self.library.refresh()
                    }
                    if refreshProgress {
                        self.requestAudioMaintenance(force: becameIdle || (completedNewWindows && !settled))
                        await self.receiver.publishStatus()
                    }
                }
            }
        }
        if let transcription { receivedAudioTranscription = ReceivedAudioTranscription(coordinator: transcription) }
        receiver.onChanged = { [weak self] in
            guard let self else { return }
            await self.transcription?.requestWork()
            await self.backgroundTasks?.scheduleAutomatic()
            if !self.libraryPresentationDeferred { await self.refresh(reconcileFiles: false) }
        }
        receiver.onFailure = { [weak self] message in self?.failure = message }
        receiver.onSyncFailure = { [weak self] message in self?.syncFailure = message }
        receiver.onAudioReceived = { [weak self] chunkID in
            guard let self else { return }
            if !self.isForeground, !self.hasTranscriptionContinuation, PhoneBackgroundTasks.resourcesAllowProcessing {
                self.receivedAudioTranscription?.request()
            }
            self.playback.requestWaveformPreparation(chunkID: chunkID, run: self.isForeground)
        }
        receiver.onStatusFailure = { [weak self] message in self?.statusFailure = message }
        receiver.onCurrentWatchStatusChanged = { [weak self] observation in
            self?.library.updateCurrentWatchStatus(observation)
        }
        backgroundTasks?.onFailure = { [weak self] message in self?.speechFailure = message }
        backgroundTasks?.onSystemTaskStarting = { [weak self] in
            await self?.receivedAudioTranscription?.handOffToSystemTask()
        }
        backgroundTasks?.onSystemTasksFinished = { [weak self] in
            self?.receivedAudioTranscription?.systemTaskFinished()
        }
        backgroundTasks?.onContinuedBatchFinished = { [weak self] id, success in
            guard let self, self.requestedTranscriptionBatchID == id else { return }
            self.requestedTranscriptionBatchID = nil
            if success, self.isForeground { Task { await self.resumeAutomaticTranscription() } }
        }
        backgroundTasks?.onResourceConditionsChanged = { [weak self] allowed in
            let constraint = PhoneBackgroundTasks.currentProcessingConstraint
            if allowed { self?.requestSpeechWarmup() }
            else {
                self?.speechWarmup?.cancel()
                self?.receivedAudioTranscription?.expire(reason: .interrupted)
            }
            Task {
                if !allowed, let self, !self.isForeground {
                    await self.transcription?.suspendForSystem()
                    self.transcriptionContinuation?.finish()
                }
                await self?.transcription?.setAnalysisPrefetchEnabled(allowed)
                await self?.transcription?.setHistoricalWorkAllowed(allowed, constraint: constraint)
            }
        }
        library.timeline.preparePlayback = { [weak self] windows in
            guard let self else { return }
            let targets = windows.filter { !$0.sources.isEmpty }.map { AudioPlaybackTarget.window($0.id, $0.sources) }
            self.playback.requestWaveformPreparation(for: targets, run: self.isForeground)
        }
        transcriptionContinuation = PhoneTranscriptionContinuation { [weak self] in
            await self?.expireForegroundTranscription()
        }
    }

    func start(backgroundOnly: Bool = false) async {
        guard !ready else { return }
        if starting {
            await withCheckedContinuation { startWaiters.append($0) }
            return
        }
        starting = true
        defer {
            starting = false
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
#if DEBUG
            if let test = uiTestConfiguration {
                try await test.stageTimeline(in: archive, fingerprint: speechFingerprint)
#if targetEnvironment(simulator)
                try await test.connectRemoteFixture(remoteAgent)
#endif
                try await test.stageWatchStatus(in: archive, receiver: receiver)
                if test.showStatusFailure { statusFailure = String(localized: "手表状态暂时无法更新，请稍后重试。") }
                uiTestConfiguration = nil
            }
#endif
            try await archive.recoverInterruptedJobs()
            try await archive.recoverPendingExpirations()
            if backgroundOnly, !isForeground { libraryPresentationDeferred = true }
            else { try await prepareLibraryPresentation() }
            ready = true
            if isForeground { playback.requestWaveformPreparation() }
            if !libraryPresentationDeferred { await refreshBatches() }
            transport?.activate()
            await receiver.reconcile()
            remoteAgent.sourcesChanged()
            await resumeAutomaticTranscription()
            await backgroundTasks?.scheduleAutomatic()
        } catch { failure = String(localized: "本机资料恢复未完成：\(error.localizedDescription)") }
    }

    private func prepareLibraryPresentation() async throws {
        try await archive.discardPunctuationOnlyTranscripts()
        do { try await archive.removeAbandonedExports() }
        catch { failure = String(localized: "上次导出的临时文件尚未清理：\(error.localizedDescription)") }
        do { try await archive.cleanDeletedFiles() }
        catch { failure = String(localized: "部分已删除资料的文件尚未清理：\(error.localizedDescription)") }
        await refresh()
    }

    func dismissFailure() {
        failure = nil
        statusFailure = nil
        syncFailure = nil
        refreshFailure = nil
        audioMaintenanceFailure = nil
    }

    func foreground() async {
        isForeground = true
        remoteAgent.foreground()
        guard isForeground else { return }
        requestSpeechWarmup()
        await transcription?.setAnalysisPrefetchEnabled(PhoneBackgroundTasks.resourcesAllowProcessing)
        await transcription?.setHistoricalWorkAllowed(PhoneBackgroundTasks.resourcesAllowProcessing,
            constraint: PhoneBackgroundTasks.currentProcessingConstraint)
        if !ready {
            receivedAudioTranscription?.expire(reason: .interrupted)
            await start()
        }
        guard ready, isForeground else { return }
        await transcription?.resumeAfterSystemSuspension()
        receivedAudioTranscription?.expire(reason: .interrupted)
        transcriptionContinuation?.finish()
        if libraryPresentationDeferred {
            do { try await prepareLibraryPresentation() }
            catch { refreshFailure = String(localized: "资料界面尚未更新：\(error.localizedDescription)"); return }
            guard isForeground else { return }
            libraryPresentationDeferred = false
        }
        playback.requestWaveformPreparation()
        transport?.allowControlReplay()
        await resumeAutomaticTranscription()
        await receiver.reconcile()
    }

    func requestWatchStatus() {
        var viewing = false
        // Background activation still requests status. Only a visible UI advertises viewing,
        // after a fresh peer report proves it understands the extra request field.
        if isForeground, let observation = receiver.currentWatchStatus, !observation.restored,
           let observedAt = observation.observedAt, (-5...30).contains(Date().timeIntervalSince(observedAt)),
           case .watch(let status) = observation.snapshot.payload, status.audioBatchVersion == 1 {
            viewing = true
        }
        transport?.requestPeerStatus(viewing: viewing)
    }

    /// Runs synchronously on scene deactivation, before iOS can suspend the process.
    func leavingForeground() {
        guard isForeground else { return }
        isForeground = false
        libraryPresentationDeferred = true
        remoteAgent.leavingForeground()
        if transcription != nil, PhoneBackgroundTasks.resourcesAllowProcessing {
            transcriptionContinuation?.start()
        }
    }

    func background() async {
        // A queued background callback must not suspend a scene that became active again.
        guard !isForeground else { return }
        remoteAgent.background()
        if transcriptionContinuation?.isActive != true && !hasTranscriptionContinuation {
            speechWarmup?.cancel()
        }
        playback.suspendWaveformPreparation()
        await transcription?.suspendForSystem(continuingForeground: transcriptionContinuation?.isActive == true)
        guard !isForeground else { return }
        await playback.stop()
        guard !isForeground else { return }
        if let transcription, !(await transcription.snapshot()).userPaused {
            await backgroundTasks?.scheduleAutomatic()
        }
    }

    /// UIKit expiration revokes the scene continuation, while a separately admitted BGTask keeps its grant.
    func expireForegroundTranscription() async {
        guard !isForeground else { return }
        await transcription?.suspendForSystem(continuingForeground: false)
        transcriptionContinuation?.finish()
    }

    func backgroundCoordinator() throws -> TranscriptionCoordinator {
        guard ready, let transcription else { throw BackgroundTranscriptionError.runtimeUnavailable }
        return transcription
    }

    /// Model preparation never participates in the archive/UI startup barrier.
    private func requestSpeechWarmup() {
        guard isForeground, PhoneBackgroundTasks.resourcesAllowProcessing, let speech,
              !speechWarmed, speechWarmup == nil, Date() >= speechWarmupRetryAt else { return }
        modelStatus = .preparing
        speechWarmup = Task(priority: .utility) { [weak self, speech] in
            defer { self?.speechWarmup = nil }
            do {
                try await speech.warmUp()
                self?.speechWarmed = true
                self?.modelStatus = .ready
            } catch is CancellationError {
                if self?.speechWarmed == false { self?.modelStatus = .awaitingValidation }
            } catch SpeechError.cancelled {
                if self?.speechWarmed == false { self?.modelStatus = .awaitingValidation }
            } catch {
                guard let self, !speechWarmed else { return }
                speechWarmupRetryAt = Date().addingTimeInterval(60)
                modelStatus = .preparationDeferred
                let native = error as NSError
                logger.error("Speech warmup failed: \(native.domain, privacy: .public) / \(native.code)")
            }
        }
    }

    private func resumeAutomaticTranscription() async {
        guard let transcription else { return }
        automaticResumeRequested = true
        guard !resumingAutomaticTranscription else { return }
        resumingAutomaticTranscription = true
        defer { resumingAutomaticTranscription = false }
        while automaticResumeRequested {
            automaticResumeRequested = false
            do {
                // Older builds exposed a persistent pause switch. The product now always processes automatically.
                if (await transcription.snapshot()).userPaused { try await transcription.resumeByUser() }
                guard isForeground, !preparingTranscriptionContinuation, requestedTranscriptionBatchID == nil else { continue }
                await transcription.resumeAfterSystemSuspension()
                guard (await transcription.snapshot()).execution == nil else { continue }
                try await transcription.preserveCompletedHistory()
                let batches = try await archive.activeTranscriptionBatches()
                activeBatches = batches
                guard isForeground, !preparingTranscriptionContinuation, requestedTranscriptionBatchID == nil else { continue }
                if let batch = batches.first(where: {
                    $0.configurationFingerprint == speechFingerprint
                        && ($0.state == .ready || ($0.state == .paused && $0.endReason == .systemEndedUnknown))
                }) {
                    if batch.state == .paused { _ = try await transcription.resumeBatch(id: batch.id) }
                    _ = try await transcription.startBatch(id: batch.id, origin: .foreground) { [weak self] completion in
                        guard completion.reason == .completed || completion.reason == .userPaused else { return }
                        Task { @MainActor in await self?.resumeAutomaticTranscription() }
                    }
                } else { await transcription.requestWork() }
            } catch { speechFailure = String(localized: "自动转写暂未恢复，音频已保留。重新打开 App 后会再试。") }
        }
    }

    private func refreshBatches() async {
        do {
            activeBatches = try await archive.activeTranscriptionBatches()
        }
        catch { speechFailure = String(localized: "无法读取本次转写进度：\(error.localizedDescription)") }
    }

    /// Called only by the user's foreground button, never by automatic recording arrival or refresh.
    func continueTranscriptionInBackground() async throws {
        guard isForeground else { throw BackgroundTranscriptionError.notForeground }
        guard !hasTranscriptionContinuation else { throw BackgroundTranscriptionError.alreadyRequested }
        guard let transcription, let backgroundTasks else { throw BackgroundTranscriptionError.runtimeUnavailable }
        guard supportsTranscriptionContinuation, PhoneBackgroundTasks.resourcesAllowProcessing else { throw BackgroundTranscriptionError.unavailable }
        preparingTranscriptionContinuation = true
        defer { preparingTranscriptionContinuation = false }
        do {
            guard let batch = try await transcription.prepareUserContinuationBatch() else {
                // Work may have finished between displaying the button and freezing the queue.
                speechFailure = nil
                await refreshBatches()
                return
            }
            requestedTranscriptionBatchID = batch.id
            try await backgroundTasks.requestBatch(id: batch.id)
            speechFailure = nil
            await refreshBatches()
        } catch {
            requestedTranscriptionBatchID = nil
            // A denied/late request leaves its frozen batch available to ordinary foreground processing.
            preparingTranscriptionContinuation = false
            if isForeground { await resumeAutomaticTranscription() }
            throw error
        }
    }

    func refresh(reconcileFiles: Bool = true) async {
        refreshRequested = true
        fileReconciliationRequested = fileReconciliationRequested || reconcileFiles
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        while refreshRequested, !Task.isCancelled {
            refreshRequested = false
            let reconcileFiles = fileReconciliationRequested
            fileReconciliationRequested = false
            var stage = String(localized: "核对录音文件")
            do {
                if reconcileFiles {
                    let reconciled = try await archive.reconcileDocumentFiles()
                    if reconciled.contains(where: \.didRevise) { await transcription?.requestWork() }
                }
                stage = String(localized: "更新资料引用")
                try await invalidatePendingContexts()
                await refreshBatches()
                stage = String(localized: "保存转录文件")
                try await archive.projectPendingDocuments(includeUnchanged: reconcileFiles)
                stage = String(localized: "清理失效聊天引用")
                refreshFailure = nil
            } catch is CancellationError { return }
            catch {
                let native = error as NSError
                logger.error("Library refresh failed at \(stage, privacy: .public): \(native.domain, privacy: .public) / \(native.code)")
                refreshFailure = String(localized: "\(stage)未完成：\(error.localizedDescription)")
            }
            // A failed file projection must not hide recordings already committed to the archive.
            await library.refresh()
            requestAudioMaintenance()
        }
    }

    /// Maintenance yields between bounded archive passes; opening the library never awaits cleanup.
    private var canCompactTranscriptHistory: Bool {
        guard PhoneBackgroundTasks.resourcesAllowProcessing, speechWarmup == nil else { return false }
        guard let snapshot = transcriptionSnapshot else { return true }
        return !snapshot.nativeInFlight && [.idle, .paused, .waitingForAudio, .waitingForContext, .waitingForRetry, .audioUnavailable, .failed].contains(snapshot.phase)
    }

    func requestAudioMaintenance(force: Bool = false) {
        if force { audioMaintenanceRequested = true }
        guard audioMaintenance == nil,
              force || Date().timeIntervalSince(lastAudioMaintenance ?? .distantPast) >= 60 else { return }
        audioMaintenanceRequested = true
        audioMaintenance = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.audioMaintenance = nil }
            repeat {
                self.audioMaintenanceRequested = false
                do {
                    if !self.obsoleteArtifactsRemoved {
                        do {
                            try await self.archive.removeObsoleteArtifacts()
                            self.obsoleteArtifactsRemoved = true
                        } catch is CancellationError { return }
                        catch { self.audioMaintenanceFailure = String(localized: "旧缓存清理未完成：\(error.localizedDescription)") }
                    }
                    try await self.archive.recoverPendingExpirations()
                    let floors: [UUID: Int64]
                    if let fingerprint = self.speechFingerprint {
                        floors = try await self.archive.analysisReplayFloors(configurationFingerprint: fingerprint)
                    } else { floors = [:] }
                    var changed = false
                    while !Task.isCancelled {
                        let removed = try await self.archive.applyRetention(replayFloors: floors, limit: 128)
                        changed = changed || !removed.isEmpty
                        if removed.count < 128 { break }
                        await Task.yield()
                    }
                    while self.canCompactTranscriptHistory && !Task.isCancelled {
                        let migrated = try await self.archive.compactTranscriptHistoryBatch()
                        if migrated == 0 {
                            try await self.archive.reclaimCompactedTranscriptStorage()
                            break
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    self.lastAudioMaintenance = Date()
                    if self.obsoleteArtifactsRemoved { self.audioMaintenanceFailure = nil }
                    if changed { await self.library.refresh() }
                } catch is CancellationError { return }
                catch {
                    self.lastAudioMaintenance = Date()
                    self.audioMaintenanceFailure = String(localized: "储存整理未完成：\(error.localizedDescription)")
                }
            } while self.audioMaintenanceRequested && !Task.isCancelled
        }
    }

    func retryTranscription(sessionID: UUID, expectedGeneration: Int64) async throws {
        guard let transcription else { throw RecordingTranscriptionRetryError.modelUnavailable }
        guard isForeground else { throw RecordingTranscriptionRetryError.busy }
        do {
            let report = try await transcription.retryTranscription(sessionID: sessionID, expectedGeneration: expectedGeneration)
            await refresh()
            let current = try await archive.recordingSummary(sessionID: sessionID)
            guard current.generation == expectedGeneration else { throw ArchiveError.staleSource }
            guard report.snapshot.phase != .failed else { throw RecordingTranscriptionRetryError.failed }
            guard report.snapshot.phase != .systemSuspended, report.snapshot.phase != .paused else {
                throw RecordingTranscriptionRetryError.busy
            }
            speechFailure = nil
        } catch {
            await refresh()
            throw error
        }
    }

    func retryTimeline(_ request: TimelineRetryRequest) async throws {
        guard let transcription else { throw RecordingTranscriptionRetryError.modelUnavailable }
        guard isForeground else { throw RecordingTranscriptionRetryError.busy }
        guard request.window.configurationFingerprint == speechFingerprint else { throw ArchiveError.staleSource }
        do {
            let selected = try await archive.timelineRetrySources(request)
            for sessionID in Set(selected.map(\.sessionID)) {
                let sources = selected.filter { $0.sessionID == sessionID }
                guard let source = sources.first else { continue }
                let report = try await transcription.retryTranscription(sessionID: sessionID,
                    expectedGeneration: source.generation, sources: sources)
                guard report.snapshot.phase != .failed else { throw RecordingTranscriptionRetryError.failed }
                guard report.snapshot.phase != .systemSuspended, report.snapshot.phase != .paused else {
                    throw RecordingTranscriptionRetryError.busy
                }
            }
            await refresh()
        } catch {
            await refresh()
            throw error
        }
    }

    func delete(sessionID: UUID) async throws {
        await playback.stop()
        do { _ = try await archive.deleteSession(id: sessionID) }
        catch {
            // The database deletion can commit before physical cleanup fails.
            receiver.clearDeletedStatus(sessionID: sessionID)
            library.removeCachedRecording(sessionID)
            await transcription?.cancel(sessionID: sessionID)
            try await invalidatePendingContexts()
            await library.refresh()
            throw error
        }
        receiver.clearDeletedStatus(sessionID: sessionID)
        library.removeCachedRecording(sessionID)
        await transcription?.cancel(sessionID: sessionID)
        try await invalidatePendingContexts()
        await library.refresh()
        await receiver.reconcile()
    }

    func resolveFiles(_ issue: RecordingFileIssue, choosing action: RecordingFileRecoveryAction) async throws {
        await playback.stop()
        do {
            let result = try await archive.resolveRecordingFiles(issue, choosing: action)
            if case .deleted = result {
                receiver.clearDeletedStatus(sessionID: issue.sessionID)
                library.removeCachedRecording(issue.sessionID)
                await transcription?.cancel(sessionID: issue.sessionID)
            }
            try await invalidatePendingContexts()
                if case .revised = result { await transcription?.requestWork() }
            await receiver.reconcile()
            await refresh()
            } catch {
            // A file operation may fail after a database change; refresh from the committed state.
            if action == .deleteRecording {
                receiver.clearDeletedStatus(sessionID: issue.sessionID)
                library.removeCachedRecording(issue.sessionID)
                await transcription?.cancel(sessionID: issue.sessionID)
                try await invalidatePendingContexts()
            }
            await refresh()
            throw error
        }
    }

    private func invalidatePendingContexts() async throws {
        remoteAgent.sourcesChanged()
    }

}

enum RecordingTranscriptionRetryError: LocalizedError {
    case modelUnavailable, busy, failed
    var errorDescription: String? {
        switch self {
        case .modelUnavailable: String(localized: "内置转写文件不可用。请安装包含完整转写文件的 App；已有录音与文字会保留。")
        case .busy: String(localized: "当前处理尚未结束，或 App 暂时无法执行。请保持 App 在前台，稍后再试。")
        case .failed: String(localized: "这次转写仍未完成，原音与已有文字已保留。请检查原音是否可用；若内置转写文件损坏，需要重新安装完整 App。")
        }
    }
}
