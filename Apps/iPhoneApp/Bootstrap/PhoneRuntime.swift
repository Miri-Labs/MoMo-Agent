import Foundation
import Observation
import OSLog
import UIKit
import MoMoAgentClient
import MoMoArchive
import MoMoLink

/// iPhone application runtime in Mac-as-Backend architecture.
///
/// iPhone runs zero local speech models. Watch and Bluetooth Earphone audio chunks arrive into
/// `ArchiveStore` and are silently relayed to Mac via `AudioUploadCoordinator`, which also pulls
/// Mac-authoritative MOSS Core ML + ReDimNet2+ transcripts back into local SQLite for offline reading.
@MainActor @Observable
final class PhoneRuntime {
    let archive: ArchiveStore
    let remoteAgent: PhoneRemoteAgent
    let uploader: AudioUploadCoordinator
    var lifeIllustrations: LifeIllustrationStore { remoteAgent.lifeIllustrations }
    let playback: AudioPlaybackController
    let speechSettings: PhoneSpeechSettings
    let library: LibraryModel
    let earphone: EarphoneCaptureRuntime?
    private(set) var failure: String?
    private(set) var statusFailure: String?
    private(set) var syncFailure: String?
    private(set) var refreshFailure: String?
    private(set) var audioMaintenanceFailure: String?
    private(set) var ready = false

    @ObservationIgnored private let receiver: PhoneReceiveCoordinator
    @ObservationIgnored private let transport: WatchConnectivityTransport?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var fileReconciliationRequested = false
    @ObservationIgnored private var lastFullFileReconciliationAt: Date?
    @ObservationIgnored private var lastDocumentProjectionUptime: Double = -.infinity
    @ObservationIgnored private var deferredProjectionTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var foregrounding = false
    @ObservationIgnored private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var transportActivated = false
    @ObservationIgnored private var fileProtectionRepaired = false
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var pendingForegroundBatchFlush = false
    @ObservationIgnored private var lastAudioMaintenance: Date?
    @ObservationIgnored private var audioMaintenance: Task<Void, Never>?
    @ObservationIgnored private var audioMaintenanceRequested = false
    @ObservationIgnored private var obsoleteArtifactsRemoved = false
    @ObservationIgnored private var libraryPresentationDeferred = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.momoagent.ios", category: "LibraryRefresh")
#if DEBUG
    @ObservationIgnored var uiTestConfiguration: PhoneUITestConfiguration?
#endif

    init(
        archive: ArchiveStore,
        remoteAgent: PhoneRemoteAgent,
        playback: AudioPlaybackController,
        receiver: PhoneReceiveCoordinator,
        transport: WatchConnectivityTransport?,
        deviceID: UUID = UUID(),
        earphone: EarphoneCaptureRuntime? = nil
    ) throws {
        self.archive = archive
        self.earphone = earphone
        self.remoteAgent = remoteAgent
        self.playback = playback
        self.receiver = receiver
        self.transport = transport
        speechSettings = PhoneSpeechSettings()
        library = LibraryModel(
            archive: archive,
            configurationFingerprint: nil,
            cachedSummaries: { [weak remoteAgent] revisions in
                remoteAgent?.cachedRecordingSummaries(revisions) ?? [:]
            },
            summarize: { [weak remoteAgent] windows in
                try await remoteAgent?.summarizeRecordings(windows) ?? [:]
            }
        )
        var refreshCallback: (@MainActor () async -> Void)?
        uploader = AudioUploadCoordinator(
            archive: archive,
            deviceID: deviceID,
            dataClientProvider: { [weak remoteAgent] in
                guard let remoteAgent, remoteAgent.store?.canContactServer != false else { return nil }
                return remoteAgent.speechDataClient
            },
            onTranscriptsUpdated: {
                await refreshCallback?()
            },
            onAuthenticationRequired: { [weak remoteAgent] error in
                remoteAgent?.store?.recordConnectionFailure(error)
            }
        )
        refreshCallback = { [weak self] in
            guard let self else { return }
            if !self.libraryPresentationDeferred {
                await self.refresh(reconcileFiles: false)
            }
        }
        remoteAgent.hasPendingAudioUpload = { [weak uploader] in
            uploader?.hasPendingWork == true
        }
        remoteAgent.onAudioRelayCycle = { [weak uploader] in
            try await uploader?.deliverInBackgroundPass()
        }
        remoteAgent.onAudioRelayCancel = { [weak uploader] in
            uploader?.cancelUpload()
        }
        remoteAgent.onNetworkPathRecovered = { [weak uploader] in
            uploader?.handleNetworkPathRecovered()
        }

        speechSettings.onDayStartHourChanged = { [weak self] in
            guard let self else { return }
            self.library.timeline.handleDayBoundaryChanged()
            Task { await self.library.refresh() }
        }
        remoteAgent.onSummariesChanged = { [weak self] in self?.library.timeline.refreshCachedSummaries() }

        receiver.onChanged = { [weak self] in await self?.archiveChanged() }
        receiver.onFailure = { [weak self] message in self?.failure = message }
        receiver.onSyncFailure = { [weak self] message in self?.syncFailure = message }
        receiver.onAudioReceived = { [weak self] chunkID in self?.audioReceived(chunkID) }

        if let earphone {
            earphone.onWillClaimAudioSession = { [weak playback] in
                await playback?.stop(deactivateImmediately: true)
            }
            playback.sessionWillActivate = { [weak earphone] in await earphone?.yieldAudioSession() }
            playback.sessionDidDeactivate = { [weak playback, weak earphone] in
                if earphone?.isActive == true {
                    playback?.deactivateHardwareSessionImmediately()
                }
                earphone?.reclaimAudioSession()
            }
        }
        // Earphone audio is archived in-process and then follows the same Mac upload path as Watch audio.
        earphone?.onDelivered = { [weak self] chunkIDs in
            guard let self else { return }
            for chunkID in chunkIDs { self.audioReceived(chunkID) }
            await self.archiveChanged()
        }
        receiver.onStatusFailure = { [weak self] message in self?.statusFailure = message }
        receiver.onStatusChanged = { [weak self] in
            guard let self, !self.libraryPresentationDeferred else { return }
            await self.library.refresh(inspectFiles: false)
        }
        receiver.onCurrentWatchStatusChanged = { [weak self] observation in
            guard let self else { return }
            self.library.updateCurrentWatchStatus(observation)
            self.remoteAgent.updateWatchStatus(observation)
            if self.isForeground, self.pendingForegroundBatchFlush,
               let observation, !observation.restored, observation.observedAt != nil,
               case .watch(let status) = observation.snapshot.payload, status.audioBatchVersion == 1 {
                self.pendingForegroundBatchFlush = false
                self.transport?.requestPeerStatus(viewing: true)
            }
        }
        library.timeline.preparePlayback = { [weak self] windows in
            guard let self else { return }
            let targets = windows.filter { !$0.sources.isEmpty }.map { AudioPlaybackTarget.window($0.id, $0.sources) }
            self.playback.requestWaveformPreparation(for: targets, run: self.isForeground)
        }
    }

    func activateTransportIfNeeded() {
        guard !transportActivated, let transport else { return }
        transportActivated = true
        transport.activate()
    }

    private func archiveChanged() async {
        if isForeground {
            uploader.requestUpload()
        } else {
            remoteAgent.contextDelivery.request()
        }
        if !libraryPresentationDeferred {
            await refresh(reconcileFiles: false, deferBurstProjection: true)
        }
    }

    private func audioReceived(_ chunkID: UUID) {
        uploader.notePendingUploadArrived()
        if isForeground {
            uploader.requestUpload()
        } else {
            // Single background grant owner: PhoneContextDelivery drives AudioUploadCoordinator.deliverInBackgroundPass().
            remoteAgent.contextDelivery.request()
        }
        playback.requestWaveformPreparation(chunkID: chunkID, run: isForeground)
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
                try await test.stageTimeline(in: archive, fingerprint: nil)
#if targetEnvironment(simulator)
                try await test.connectRemoteFixture(remoteAgent)
                try await test.configureLifeIllustrations(lifeIllustrations)
#endif
                try await test.stageWatchStatus(in: archive, receiver: receiver)
                if test.showStatusFailure { statusFailure = String(localized: "手表状态暂时无法更新，请稍后重试。") }
                uiTestConfiguration = nil
            }
#endif
            let coldStartStartedMs = APIPerformanceMonitor.uptimeMilliseconds()
            try await archive.recoverInterruptedJobs()
            try await archive.recoverPendingExpirations()
            if backgroundOnly, !isForeground { libraryPresentationDeferred = true }
            else { try await prepareLibraryPresentation(coldStartStartedMs: coldStartStartedMs) }
            ready = true
            if isForeground { playback.requestWaveformPreparation() }
            activateTransportIfNeeded()
            await receiver.reconcile()
            remoteAgent.updateWatchStatus(receiver.currentWatchStatus)
            remoteAgent.sourcesChanged()
            await uploader.refreshCounts()
            if isForeground {
                uploader.foreground()
            } else if uploader.hasPendingWork {
                remoteAgent.contextDelivery.request()
            }
        } catch { failure = String(localized: "本机资料恢复未完成：\(error.localizedDescription)") }
    }

    private func prepareLibraryPresentation(coldStartStartedMs: Double? = nil) async throws {
        try await archive.discardPunctuationOnlyTranscripts()
        try await archive.upgradeSpeakerProfilesIfNeeded()
        await library.refresh(inspectFiles: false)
        if let coldStartStartedMs {
            archive.performanceMonitor.record(
                .coldStartToTimelineInteractive,
                durationMs: APIPerformanceMonitor.uptimeMilliseconds() - coldStartStartedMs,
                itemCount: library.recordings.count
            )
        }
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
        library.dismissSpeakerFeedbackFailure()
        receiver.dismissFailures()
    }

    func foreground() async {
        isForeground = true
        remoteAgent.foreground()
        if foregrounding {
            await withCheckedContinuation { foregroundWaiters.append($0) }
            return
        }
        foregrounding = true
        defer {
            foregrounding = false
            let waiters = foregroundWaiters
            foregroundWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        guard isForeground else { return }
        if !fileProtectionRepaired {
            fileProtectionRepaired = true
            let archive = self.archive
            Task.detached(priority: .utility) { await archive.repairFileProtectionIfNeeded() }
        }
        let startedCold = !ready
        if startedCold {
            await start()
        }
        guard ready, isForeground else { return }
        // iOS only lets capture start in the foreground.
        await earphone?.foreground()
        transport?.allowControlReplay()
        requestWatchStatus()
        await receiver.reconcile()
        remoteAgent.updateWatchStatus(receiver.currentWatchStatus)
        uploader.foreground()
        if libraryPresentationDeferred {
            do { try await prepareLibraryPresentation() }
            catch { refreshFailure = String(localized: "资料界面尚未更新：\(error.localizedDescription)"); return }
            guard isForeground else { return }
            libraryPresentationDeferred = false
        } else if !startedCold {
            await refresh(reconcileFiles: true)
            guard isForeground else { return }
        }
        playback.requestWaveformPreparation()
    }

    func requestWatchStatus() {
        var viewing = false
        if isForeground, let observation = receiver.currentWatchStatus,
           case .watch(let status) = observation.snapshot.payload, status.audioBatchVersion == 1 {
            viewing = true
            pendingForegroundBatchFlush = false
        } else if isForeground {
            pendingForegroundBatchFlush = true
        }
        transport?.requestPeerStatus(viewing: viewing)
    }

    /// Runs synchronously on scene deactivation, before iOS can suspend the process.
    func leavingForeground() {
        guard isForeground else { return }
        isForeground = false
        lastFullFileReconciliationAt = nil
        pendingForegroundBatchFlush = false
        uploader.background()
        remoteAgent.leavingForeground()
    }

    func background() async {
        guard !isForeground else { return }
        libraryPresentationDeferred = true
        uploader.background()
        remoteAgent.background()
        playback.suspendWaveformPreparation()
        guard !isForeground else { return }
        await playback.stop(deactivateImmediately: true)
        try? archive.performanceMonitor.flushNow()
    }

    func didMutateSpeakers() async {
        await uploader.syncRemoteTranscriptsFromMac(force: true)
        await library.refresh()
        remoteAgent.sourcesChanged()
    }

    func didCommitTargetedSpeakerFeedback() async {
        await uploader.syncRemoteTranscriptsFromMac(force: true)
        await library.refresh()
        remoteAgent.sourcesChanged()
    }

    func prepareSourcesForDiscussion(_ sources: [SourceReference]) async -> [SourceReference] {
        await library.awaitPendingSpeakerFeedback()
        guard !sources.isEmpty else { return [] }
        return (try? await archive.resolveCurrentSpeakerSources(sources)) ?? sources
    }

    func refreshLibraryOnAppear() async {
        lifeIllustrations.requestRefresh(minimumInterval: 5)
        uploader.requestUpload()
        await uploader.syncRemoteTranscriptsFromMac()
        await library.timeline.refresh()
        if !library.hasLoadedOnce {
            await library.refresh(inspectFiles: false)
        }
        if let last = lastFullFileReconciliationAt, Date().timeIntervalSince(last) < 30 {
            return
        }
        await refresh(reconcileFiles: false)
    }

    func refresh(reconcileFiles: Bool = true, deferBurstProjection: Bool = false) async {
        if reconcileFiles {
            remoteAgent.sourcesChanged()
            lifeIllustrations.requestRefresh()
            uploader.requestUpload()
            await uploader.syncRemoteTranscriptsFromMac()
        }
        let nowUptime = Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
        if deferBurstProjection, !reconcileFiles, nowUptime - lastDocumentProjectionUptime < 10.0 {
            await library.refresh(inspectFiles: false)
            scheduleDeferredDocumentProjection()
            return
        }
        deferredProjectionTask?.cancel()
        deferredProjectionTask = nil
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
                _ = try await archive.reconcileDocumentFiles(onlyBlockedOrChanged: !reconcileFiles)
                if reconcileFiles { lastFullFileReconciliationAt = Date() }
                stage = String(localized: "保存转录文件")
                try await archive.projectPendingDocuments(includeUnchanged: false)
                lastDocumentProjectionUptime = Double(DispatchTime.now().uptimeNanoseconds) * 1e-9
                stage = String(localized: "更新资料引用")
                try await invalidatePendingContexts()
                refreshFailure = nil
            } catch is CancellationError { return }
            catch {
                let native = error as NSError
                logger.error("Library refresh failed at \(stage, privacy: .public): \(native.domain, privacy: .public) / \(native.code)")
                refreshFailure = String(localized: "\(stage)未完成：\(error.localizedDescription)")
            }
            await library.refresh(inspectFiles: reconcileFiles)
            requestAudioMaintenance()
        }
    }

    private func scheduleDeferredDocumentProjection() {
        guard deferredProjectionTask == nil else { return }
        deferredProjectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.deferredProjectionTask = nil
            guard !self.libraryPresentationDeferred else { return }
            await self.refresh(reconcileFiles: false, deferBurstProjection: false)
        }
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
                    var changed = false
                    while !Task.isCancelled {
                        // Retention automatically protects unuploaded chunks via mac_audio_uploads.
                        let removed = try await self.archive.applyRetention(replayFloors: [:], limit: 128)
                        changed = changed || !removed.isEmpty
                        if removed.count < 128 { break }
                        await Task.yield()
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

    func delete(sessionID: UUID) async throws {
        await playback.stop()
        let wasMacOwned = (try? await archive.macAuthoritativeSessionIDs().contains(sessionID)) ?? false
        let preDeleteSummary = try? await archive.recordingSummary(sessionID: sessionID)
        do { _ = try await archive.deleteSession(id: sessionID) }
        catch {
            receiver.clearDeletedStatus(sessionID: sessionID)
            library.removeCachedRecording(sessionID)
            try await invalidatePendingContexts()
            await library.refresh()
            throw error
        }
        if wasMacOwned, let summary = preDeleteSummary {
            await remoteAgent.context?.tombstoneMacSession(
                sessionID,
                generation: summary.generation,
                version: summary.transcriptVersion,
                recordedAt: summary.recordedAt
            )
        }
        receiver.clearDeletedStatus(sessionID: sessionID)
        library.removeCachedRecording(sessionID)
        try await invalidatePendingContexts()
        await library.refresh()
        await receiver.reconcile()
        earphone?.requestDelivery()
    }

    func resolveFiles(_ issue: RecordingFileIssue, choosing action: RecordingFileRecoveryAction) async throws {
        await playback.stop()
        do {
            let result = try await archive.resolveRecordingFiles(issue, choosing: action)
            if case .deleted = result {
                receiver.clearDeletedStatus(sessionID: issue.sessionID)
                library.removeCachedRecording(issue.sessionID)
            }
            try await invalidatePendingContexts()
            await receiver.reconcile()
            await refresh()
        } catch {
            if action == .deleteRecording {
                receiver.clearDeletedStatus(sessionID: issue.sessionID)
                library.removeCachedRecording(issue.sessionID)
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
