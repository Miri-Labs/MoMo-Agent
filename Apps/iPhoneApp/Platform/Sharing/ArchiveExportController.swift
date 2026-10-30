import Foundation
import Observation
import MoMoArchive

@MainActor @Observable
final class ArchiveExportController {
    private(set) var presented: ArchiveExport?
    private(set) var preparing = false
    private(set) var cleanupNeeded = false
    var failure: String?
    var busy: Bool { preparing || active != nil || awaitingDismissal }
    @ObservationIgnored private var preparation: Task<Void, Never>?
    private var active: (archive: ArchiveStore, artifact: ArchiveExport)?
    private var awaitingDismissal = false
    @ObservationIgnored private var cleaning = false

    func start(recording: RecordingSummary, content: RecordingExportContent, archive: ArchiveStore) {
        start(archive: archive) {
            try await archive.prepareRecordingExport(sessionID: recording.sessionID,
                expectedGeneration: recording.generation, expectedTranscriptVersion: recording.transcriptVersion,
                content: content)
        }
    }

    func start(scope: TimelineExportScope, configurationFingerprint: String?, archive: ArchiveStore) {
        start(archive: archive) {
            try await archive.prepareTimelineExport(scope: scope, configurationFingerprint: configurationFingerprint)
        }
    }

    private func start(archive: ArchiveStore, prepare: @escaping @Sendable () async throws -> ArchiveExport) {
        guard !busy else { return }
        preparing = true
        failure = nil
        preparation = Task {
            var staged: ArchiveExport?
            defer { preparing = false; preparation = nil }
            do {
                let artifact = try await prepare()
                staged = artifact
                try Task.checkCancellation()
                try await archive.validateExportSource(artifact)
                try Task.checkCancellation()
                active = (archive, artifact)
                awaitingDismissal = true
                presented = artifact
            } catch {
                if !(error is CancellationError) { failure = Self.message(for: error) }
                if let staged {
                    active = (archive, staged)
                    await cleanActive()
                }
            }
        }
    }

    func cancelPreparation() { preparation?.cancel() }

    func activityCompleted(id: UUID, errorMessage: String?) {
        guard active?.artifact.id == id else { return }
        presented = nil
        if let errorMessage { failure = errorMessage }
        Task { await cleanActive() }
    }

    func requestPresentationDismissal() { presented = nil }

    func presentationDismissed() {
        presented = nil
        awaitingDismissal = false
        // Dismissing SwiftUI's sheet is not proof the selected extension finished reading.
        // The UIKit completion callback owns cleanup, including cancellation. Cold start recovers a killed process.
    }

    func retryCleanup() { Task { await cleanActive() } }

    private func cleanActive() async {
        guard let active, !cleaning else { return }
        cleaning = true
        defer { cleaning = false }
        do {
            try await active.archive.removeExport(active.artifact)
            self.active = nil
            cleanupNeeded = false
        } catch {
            cleanupNeeded = true
            failure = String(localized: "临时导出副本尚未清理，请重试。")
        }
    }

    private static func message(for error: any Error) -> String {
        if let exportError = error as? ArchiveExportError {
            switch exportError {
            case .audioUnavailable: return String(localized: "当前没有可导出的原音，或原音在准备期间已清理。你仍可单独导出转录。")
            case .sourceChanged: return String(localized: "资料在准备导出时发生变化，请刷新后重新导出。")
            case .unsafeTemporaryPath: return String(localized: "临时导出目录不可用，请重启 App 后重试。")
            case .noTranscriptInRange: return String(localized: "这个时间范围还没有可分享的文字。")
            }
        }
        if let archiveError = error as? ArchiveError {
            switch archiveError {
            case .missingTranscript: return String(localized: "这次录音尚无转录，可以先导出原音。")
            case .projectionConflict, .projectionPending: return String(localized: "转录文件尚未就绪或存在冲突，请先处理资料状态。")
            case .missingRecording, .checksumMismatch, .byteCountMismatch: return String(localized: "原音缺失或校验失败，导出已停止。")
            case .sessionDeleted, .staleSource: return String(localized: "资料已删除或已更新，请重新打开后导出。")
            default: break
            }
        }
        if let fileError = error as? CocoaError, fileError.code == .fileWriteOutOfSpace {
            return String(localized: "设备剩余空间不足，无法准备导出副本。")
        }
        return String(localized: "导出未完成：\(error.localizedDescription)")
    }
}
