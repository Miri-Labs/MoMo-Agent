import Foundation
import SwiftUI
import UIKit
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

@MainActor
final class LibraryPaginationIntegrationTests: XCTestCase {
    func testPrefetchedSnapshotIsAvailableAndInvalidatesOnRevisionAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPrefetch-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let (document, _) = try await makeReadingFixture(archive: archive, root: root)
        let model = LibraryModel(archive: archive)
        await model.refresh()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.cachedTranscript(document.sessionID) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.cachedTranscript(document.sessionID)?.document.version, document.version)
        XCTAssertEqual(model.previews[document.sessionID], String(document.spans[0].text.prefix(160)))
        let revised = try await archive.reviseTranscript(sessionID: document.sessionID, expectedVersion: document.version, spans: [])
        await model.refresh()
        if let cached = model.cachedTranscript(document.sessionID) { XCTAssertEqual(cached.document.version, revised.version) }
        let fresh = try await model.loadTranscript(document.sessionID)
        XCTAssertTrue(fresh.document.spans.isEmpty)
        _ = try await archive.deleteSession(id: document.sessionID)
        model.removeCachedRecording(document.sessionID)
        XCTAssertNil(model.cachedTranscript(document.sessionID))
        do { _ = try await model.loadTranscript(document.sessionID); XCTFail("Deleted text cannot be returned from cache") }
        catch ArchiveError.missingRecording { }
    }

    func testTranscriptionStatusRequiresMatchingNativeWorkAndDoesNotSuspendFinishedRecordings() {
        let session = UUID(), other = UUID()
        func snapshot(_ phase: MoMoAgent.TranscriptionPhase, active: UUID? = nil, native: Bool = false,
                      failed: UUID? = nil) -> MoMoAgent.TranscriptionSnapshot {
            MoMoAgent.TranscriptionSnapshot(phase: phase, userPaused: phase == .paused, activeSessionID: active,
                                  completedWindows: 0, failureCode: nil, execution: nil, batch: nil,
                                  nativeInFlight: native, failedSessionID: failed)
        }
        func presentation(_ state: RecordingTranscriptionState, _ value: MoMoAgent.TranscriptionSnapshot?) -> RecordingTranscriptionPresentation {
            RecordingTranscriptionPresentation(sessionID: session, state: state, snapshot: value)
        }
        for stopped in [MoMoAgent.TranscriptionPhase.systemSuspended, .paused] {
            XCTAssertEqual(presentation(.processing, snapshot(stopped)).activity, .deferred,
                           "A cached running row cannot override a stopped runtime.")
            XCTAssertFalse(presentation(.processing, snapshot(stopped)).isActive)
            for finished in [RecordingTranscriptionState.transcribed, .noSpeech, .completedWithoutText] {
                XCTAssertEqual(presentation(finished, snapshot(stopped)).activity, .finished,
                               "Global suspension must not relabel completed recordings.")
                XCTAssertNil(presentation(finished, snapshot(stopped)).status)
            }
        }
        XCTAssertEqual(presentation(.processing, snapshot(.transcribing, active: session)).activity, .queued)
        XCTAssertEqual(presentation(.processing, nil).activity, .queued)
        XCTAssertEqual(presentation(.pending, snapshot(.transcribing, active: other, native: true)).activity, .queued)
        XCTAssertEqual(presentation(.processing, snapshot(.transcribing, active: session, native: true)).activity, .transcribing)
        XCTAssertEqual(presentation(.pending, snapshot(.preparing, active: session, native: true)).activity, .preparing)
        XCTAssertEqual(presentation(.transcribed, snapshot(.transcribing, active: session, native: true)).activity, .transcribing,
                       "A real newly appended window is active even before the archive list refreshes.")
        XCTAssertEqual(presentation(.processing, snapshot(.failed, failed: session)).activity, .failed)
        XCTAssertEqual(presentation(.processing, snapshot(.failed, failed: other)).activity, .queued)
        XCTAssertEqual(presentation(.failed, snapshot(.transcribing, active: other, native: true)).activity, .failed)
    }

    func testTimelineStatusUsesNativeWorkAndPreservesCompletedAndFailedCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoTimelineStatus-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let (document, writer) = try await makeReadingFixture(archive: archive, root: root,
            at: Date(timeIntervalSince1970: 1_792_023_100))
        let first = try XCTUnwrap(document.spans.first)
        let completedValue = try await archive.timelineWindow(containing: document.source(for: first))
        let completed = try XCTUnwrap(completedValue)
        XCTAssertEqual(completed.state, .complete)
        var nextWriter = writer
        let chunk = try XCTUnwrap(nextWriter.append([Int16](repeating: 0, count: 1600)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
        let pendingValue = try await archive.timelineWindow(completed.id)
        let pending = try XCTUnwrap(pendingValue)
        XCTAssertEqual(pending.state, .waitingForTranscription)
        XCTAssertFalse(pending.references.isEmpty, "Previously completed text remains readable while more audio is pending.")

        func snapshot(_ phase: MoMoAgent.TranscriptionPhase, active: UUID? = nil, native: Bool = false,
                      failed: UUID? = nil) -> MoMoAgent.TranscriptionSnapshot {
            MoMoAgent.TranscriptionSnapshot(phase: phase, userPaused: phase == .paused, activeSessionID: active,
                completedWindows: 1, failureCode: nil, execution: nil, batch: nil,
                nativeInFlight: native, failedSessionID: failed)
        }
        for phase in [MoMoAgent.TranscriptionPhase.paused, .systemSuspended] {
            XCTAssertEqual(TimelinePresentation.status(pending, transcription: snapshot(phase), speechFailure: nil), "稍后继续")
            XCTAssertNil(TimelinePresentation.status(completed, transcription: snapshot(phase), speechFailure: nil))
        }
        for phase in [MoMoAgent.TranscriptionPhase.preparing, .transcribing] {
            XCTAssertEqual(TimelinePresentation.status(pending,
                transcription: snapshot(phase, active: document.sessionID), speechFailure: nil), "等待整理",
                "A session ID alone must not claim that the native call is still executing.")
            XCTAssertEqual(TimelinePresentation.status(pending,
                transcription: snapshot(phase, active: document.sessionID, native: true), speechFailure: nil), "正在整理")
            XCTAssertEqual(TimelinePresentation.status(pending,
                transcription: snapshot(phase, active: UUID(), native: true), speechFailure: nil), "等待整理")
            XCTAssertNil(TimelinePresentation.status(completed,
                transcription: snapshot(phase, active: document.sessionID, native: true), speechFailure: nil),
                "Work on another window of the same recording must not relabel a completed window.")
        }
        XCTAssertEqual(TimelinePresentation.status(pending, transcription: nil, speechFailure: nil), "等待整理")
        XCTAssertEqual(TimelinePresentation.status(pending, transcription: snapshot(.idle), speechFailure: "fixed-model-unavailable"), "未能整理")
        XCTAssertEqual(TimelinePresentation.status(pending, transcription: snapshot(.failed, failed: UUID()), speechFailure: nil), "等待整理")
        XCTAssertEqual(TimelinePresentation.status(pending,
            transcription: snapshot(.failed, failed: document.sessionID), speechFailure: nil), "部分未完成")

        let claimed = try await archive.claimAnalysisJob(configurationHash: "reading-position")
        let ticket = try XCTUnwrap(claimed)
        try await archive.failAnalysis(ticket: ticket, errorCode: "fixture-native-failure", retryable: false)
        let failedValue = try await archive.timelineWindow(completed.id)
        let failed = try XCTUnwrap(failedValue)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(TimelinePresentation.status(failed, transcription: snapshot(.systemSuspended), speechFailure: nil), "部分未完成",
                       "Known failed coverage must not be hidden behind global suspension.")
    }

    func testReadingAnchorSurvivesAppendAndRejectsRevisionDeletionAndLateCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoReadingIdentity-\(UUID())")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let (document, writer) = try await makeReadingFixture(archive: archive, root: root)
        var continuingWriter = writer
        let model = LibraryModel(archive: archive)
        await model.refresh()
        let anchor = document.spans[12].id
        model.rememberReadingPosition(anchor, in: document)
        XCTAssertEqual(model.readingAnchor(in: document), anchor)

        let appended = try XCTUnwrap(continuingWriter.append([Int16](repeating: 0, count: 1600)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: appended.audioURL, envelope: appended.envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "reading-position")
        let ticket = try XCTUnwrap(claimed)
        let updated = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "后续新到的正文")
        ])
        await model.refresh()
        XCTAssertEqual(updated.generation, document.generation)
        XCTAssertGreaterThan(updated.version, document.version)
        XCTAssertEqual(model.readingAnchor(in: updated), anchor)
        model.rememberReadingPosition(document.spans[0].id, in: document)
        XCTAssertEqual(model.readingAnchor(in: updated), anchor, "An old layout callback must not replace a newer document's position.")

        let revised = try await archive.reviseTranscript(sessionID: document.sessionID, expectedVersion: updated.version,
                                                         spans: updated.spans)
        await model.refresh()
        XCTAssertNil(model.readingAnchor(in: revised), "A new generation must not inherit an unvalidated old anchor.")
        model.rememberReadingPosition(anchor, in: revised)
        XCTAssertEqual(model.readingAnchor(in: revised), anchor)
        _ = try await archive.deleteSession(id: document.sessionID)
        model.removeCachedRecording(document.sessionID)
        model.rememberReadingPosition(anchor, in: revised)
        XCTAssertNil(model.readingAnchor(in: revised), "A disappearing detail cannot resurrect a deleted reading position.")
    }

    func testDetailRestoresActualScrollAfterRecreationAndKeepsPositionWhenTextAppends() async throws {
        try await verifyDetailReadingRestoration(shortParagraphs: false)
    }

    func testShortParagraphRestoresBelowPinnedPlayerAndKeepsPositionWhenTextAppends() async throws {
        try await verifyDetailReadingRestoration(shortParagraphs: true)
    }

    func testDetailRestoresActualScrollAfterNavigationPopPushAndKeepsPositionWhenTextAppends() async throws {
        try await verifyDetailReadingRestoration(shortParagraphs: false, navigationMode: .sameStack)
    }

    private func verifyDetailReadingRestoration(shortParagraphs: Bool,
                                                navigationMode: ReadingNavigationMode = .replaceController) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoReadingScroll-\(UUID())")
        let lifetime = ReadingViewLifetime()
        addTeardownBlock { @MainActor in
            lifetime.window?.isHidden = true
            lifetime.window?.rootViewController = nil
            await lifetime.playback?.stop()
            let deadline = ContinuousClock.now + .seconds(10)
            while lifetime.hasOwners && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(lifetime.hasOwners, "Reading fixture is still owned: \(lifetime.description). Retaining its directory instead of unlinking an open database.")
            guard !lifetime.hasOwners else { return }
            try FileManager.default.removeItem(at: root)
        }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        lifetime.archive = archive
        let (document, writer) = try await makeReadingFixture(archive: archive, root: root,
                                                            shortParagraphs: shortParagraphs)
        var continuingWriter = writer
        let model = LibraryModel(archive: archive)
        lifetime.model = model
        await model.refresh()
        let playback = AudioPlaybackController(archive: archive)
        lifetime.playback = playback
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        lifetime.window = window
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var readingTrace = ["navigation-mode=\(navigationMode)"]
        var readingObservations: [Int: RecordingReadingDiagnostic] = [:]
        var readingFrames: [Int: [UUID: CGRect]] = [:]
        var readingFrameVersions: [Int: [UUID: Int64]] = [:]
        var loadedDocuments = 0
        var incarnation = 0
        let navigation = navigationMode == .sameStack ? ReadingNavigationPath() : nil
        var homeVisible = false
        var homeFrame = CGRect.zero
        var disappearedDetails: Set<Int> = []
        defer {
            let attachment = XCTAttachment(string: readingTrace.joined(separator: "\n"))
            attachment.name = "reading-identity-and-geometry-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func detail(_ currentIncarnation: Int) -> RecordingDetailView {
            RecordingDetailView(sessionID: document.sessionID, library: model, playback: playback,
                    delete: { _ in }, canDiscuss: false, discuss: { _ in },
                    readingPositionObserver: { [weak window] event in
                        if event.event.hasPrefix("loaded-") { loadedDocuments += 1 }
                        readingObservations[currentIncarnation] = event
                        if let id = event.spanID {
                            if let frame = event.frame {
                                readingFrames[currentIncarnation, default: [:]][id] = frame
                                readingFrameVersions[currentIncarnation, default: [:]][id] = event.version
                            }
                            if event.event == "disappear" { readingFrames[currentIncarnation]?[id] = nil }
                        }
                        if readingTrace.count < 600 {
                            let scroll = window.flatMap { self.readingScroll(in: $0) }
                            readingTrace.append("view=\(currentIncarnation) nativeOffset=\(String(describing: scroll?.contentOffset.y)) contentSize=\(String(describing: scroll?.contentSize)) \(event.description)")
                        }
                    })
        }
        func showDetail() {
            incarnation += 1
            let currentIncarnation = incarnation
            if let navigation {
                navigation.path = [currentIncarnation]
                if window.rootViewController == nil {
                    window.rootViewController = UIHostingController(rootView: ReadingNavigationContainer(
                        navigation: navigation,
                        homeVisibility: { homeVisible = $0 }, homeGeometry: { homeFrame = $0 },
                        destination: { route in
                            detail(route).onDisappear {
                                disappearedDetails.insert(route)
                                readingTrace.append("navigation-detail-disappeared view=\(route)")
                            }
                        }).environment(\.dynamicTypeSize, .large))
                    window.makeKeyAndVisible()
                }
            } else {
                window.rootViewController = UIHostingController(rootView: NavigationStack {
                    detail(currentIncarnation)
                }.environment(\.dynamicTypeSize, .large))
                window.makeKeyAndVisible()
            }
        }
        showDetail()
        try await waitForReadingCondition(in: window, stage: "initial-layout") {
            window.layoutIfNeeded()
            return self.readingScroll(in: window) != nil
        }
        let initial = try XCTUnwrap(readingScroll(in: window))
        initial.setContentOffset(CGPoint(x: 0, y: 2400), animated: false)
        readingTrace.append("requested-native-scroll=2400 actual=\(initial.contentOffset.y)")
        try await waitForReadingCondition(in: window, stage: "first-scroll-anchor") {
            guard let id = model.readingAnchor(in: document), let index = document.spans.firstIndex(where: { $0.id == id }) else { return false }
            if shortParagraphs {
                guard index < document.spans.count - 5, let observation = readingObservations[1],
                      let frame = readingFrames[1]?[id], observation.occludedTop > 0 else { return false }
                return index > 2 && initial.contentOffset.y > 2000
                    && min(frame.maxY, observation.viewportHeight) - max(frame.minY, observation.occludedTop) > 44
            }
            return index > 2 && initial.contentOffset.y > 2000
        }
        let anchor = try XCTUnwrap(model.readingAnchor(in: document))
        let initialFrame = try XCTUnwrap(readingFrames[1]?[anchor])
        let initialViewport = try XCTUnwrap(readingObservations[1]).viewportHeight
        XCTAssertGreaterThan(min(initialFrame.maxY, initialViewport) - max(initialFrame.minY, 0), 44,
                             "The saved paragraph must actually be readable before leaving.")
        if shortParagraphs {
            let observation = try XCTUnwrap(readingObservations[1])
            XCTAssertLessThan(try XCTUnwrap(document.spans.firstIndex(where: { $0.id == anchor })), document.spans.count - 5)
            XCTAssertGreaterThan(observation.occludedTop, 0, "The short-row case must exercise the actually pinned player.")
            XCTAssertGreaterThan(min(initialFrame.maxY, initialViewport) - max(initialFrame.minY, observation.occludedTop), 44)
        }
        readingTrace.append("leave anchor=\(anchor) index=\(document.spans.firstIndex(where: { $0.id == anchor })!) offset=\(initial.contentOffset.y) frame=\(initialFrame)")
        attachReadingScreenshot(window, name: "reading-before-leaving")
        if let navigation {
            let controllerIdentity = ObjectIdentifier(try XCTUnwrap(window.rootViewController))
            navigation.path.removeAll()
            try await waitForReadingCondition(in: window, stage: "navigation-popped-to-home") {
                window.layoutIfNeeded()
                return navigation.path.isEmpty && homeVisible && disappearedDetails.contains(1)
                    && homeFrame.intersection(window.bounds).height > 100
                    && self.readingScroll(in: window) == nil
            }
            readingTrace.append("navigation-home-visible frame=\(homeFrame) old-detail-disappeared=true")
            attachReadingScreenshot(window, name: "reading-navigation-home-after-pop")
            showDetail()
            XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.rootViewController)), controllerIdentity,
                           "Pop and push must retain the same hosting controller and NavigationStack.")
        } else {
            window.rootViewController = UIViewController() // Destroy the detail's @State, like popping navigation.
            await Task.yield()
            showDetail()
        }
        func stableReadingFrame(in expected: TranscriptDocument, stage: String) async throws -> CGRect {
            var candidateFrame: CGRect?
            var candidateVisibleIDs: [UUID] = []
            var stableChecks = 0
            try await waitForReadingCondition(in: window, stage: stage) {
                window.layoutIfNeeded()
                guard let observation = readingObservations[2], let frame = readingFrames[2]?[anchor],
                      observation.version == expected.version,
                      observation.spanCount == expected.spans.count,
                      readingFrameVersions[2]?[anchor] == expected.version,
                      observation.restoringSpanID == nil, observation.visibleSpanIDs.first == anchor,
                      model.readingAnchor(in: expected) == anchor,
                      min(frame.maxY, observation.viewportHeight) - max(frame.minY, 0) > 44,
                      !shortParagraphs || (observation.occludedTop > 0
                        && min(frame.maxY, observation.viewportHeight) - max(frame.minY, observation.occludedTop) > 44) else {
                    candidateFrame = nil
                    candidateVisibleIDs = []
                    stableChecks = 0
                    return false
                }
                if let candidateFrame,
                   candidateVisibleIDs == observation.visibleSpanIDs,
                   abs(frame.minX - candidateFrame.minX) <= 0.25,
                   abs(frame.minY - candidateFrame.minY) <= 0.25,
                   abs(frame.width - candidateFrame.width) <= 0.25,
                   abs(frame.height - candidateFrame.height) <= 0.25 {
                    stableChecks += 1
                } else {
                    candidateFrame = frame
                    candidateVisibleIDs = observation.visibleSpanIDs
                    stableChecks = 1
                }
                return stableChecks >= 3
            }
            let frame = try XCTUnwrap(readingFrames[2]?[anchor])
            readingTrace.append("stable-layout stage=\(stage) version=\(expected.version) frame=\(frame)")
            return frame
        }
        _ = try await stableReadingFrame(in: document, stage: "restored-anchor")
        attachReadingScreenshot(window, name: "reading-after-restore")
        // Capturing UIKit can flush a final native layout correction. Read the baseline
        // only after that capture has also satisfied the same current-document checks.
        let restoredFrame = try await stableReadingFrame(in: document, stage: "restored-anchor-after-screenshot")
        let restored = try XCTUnwrap(readingScroll(in: window))
        let restoredObservation = try XCTUnwrap(readingObservations[2])
        XCTAssertNil(restoredObservation.restoringSpanID, "Append must not start while the restore is still in progress.")
        XCTAssertEqual(restoredObservation.visibleSpanIDs.first, anchor)
        XCTAssertGreaterThan(min(restoredFrame.maxY, restoredObservation.viewportHeight) - max(restoredFrame.minY, 0), 44,
                             "Restoration must show the same saved paragraph in the reading viewport.")
        if shortParagraphs {
            XCTAssertGreaterThan(restoredObservation.occludedTop, 0)
            XCTAssertGreaterThan(min(restoredFrame.maxY, restoredObservation.viewportHeight)
                - max(restoredFrame.minY, restoredObservation.occludedTop), 44,
                "The same short paragraph must be readable below the actual pinned player, not hidden behind it.")
        }
        // A LazyVStack estimates unmounted rows. Its absolute contentOffset can change
        // when those estimates are refined while this paragraph stays fixed on screen.
        // Measure the actual paragraph's viewport frame, not that changing content origin.
        readingTrace.append("restore-verified nativeOffset=\(restored.contentOffset.y) frame=\(restoredFrame)")
        let loadedBeforeRefresh = loadedDocuments
        for _ in 0..<5 { await model.refresh(); await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loadedDocuments, loadedBeforeRefresh,
                       "Unchanged library refreshes must not restart transcript loading.")
        let appended = try XCTUnwrap(continuingWriter.append([Int16](repeating: 0, count: 1600)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: appended.audioURL, envelope: appended.envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "reading-position")
        let ticket = try XCTUnwrap(claimed)
        let updated = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames,
                           text: String(repeating: "新到的文字只应追加，不应该把阅读位置拉回开头。", count: 20))
        ])
        await model.refresh()
        _ = try await stableReadingFrame(in: updated, stage: "appended-layout")
        attachReadingScreenshot(window, name: "reading-after-append")
        let appendedFrame = try await stableReadingFrame(in: updated, stage: "appended-layout-after-screenshot")
        XCTAssertEqual(appendedFrame.minY, restoredFrame.minY, accuracy: 4,
                       "Appending below the visible paragraph must preserve its actual viewport position.")
        XCTAssertEqual(appendedFrame.height, restoredFrame.height, accuracy: 4)
        XCTAssertEqual(model.readingAnchor(in: updated), anchor)
        if shortParagraphs {
            let observation = try XCTUnwrap(readingObservations[2])
            XCTAssertGreaterThan(observation.occludedTop, 0)
            XCTAssertGreaterThan(min(appendedFrame.maxY, observation.viewportHeight)
                - max(appendedFrame.minY, observation.occludedTop), 44)
        }
        readingTrace.append("append-verified nativeOffset=\(restored.contentOffset.y) frame=\(appendedFrame)")
        window.rootViewController = nil
        await playback.stop()
    }

    private func attachReadingScreenshot(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let evidence = XCTAttachment(image: image)
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func makeReadingFixture(archive: ArchiveStore, root: URL, at: Date = .now,
                                    shortParagraphs: Bool = false) async throws -> (TranscriptDocument, PCM16SegmentWriter) {
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("reading-input"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "reading-position-fixture", sourceKind: .fixture, targetFrames: 1600,
            wallClockAnchor: at, timezoneOffset: 0)
        let chunk = try XCTUnwrap(writer.append([Int16](repeating: 0, count: 1600)).first)
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "reading-position")
        let ticket = try XCTUnwrap(claimed)
        let count = shortParagraphs ? 80 : 20
        let framesPerSpan = ticket.manifest.frames.count / Int64(count)
        XCTAssertGreaterThan(framesPerSpan, 0)
        XCTAssertEqual(ticket.manifest.frames.count % Int64(count), 0)
        let spans = try (0..<count).map { index in
            TranscriptSpan(chunkID: ticket.chunkID,
                frames: try FrameRange(start: ticket.manifest.frames.start + Int64(index) * framesPerSpan, count: framesPerSpan),
                text: shortParagraphs ? "第\(index + 1)段。记下一句话。"
                    : "第\(index + 1)段。" + String(repeating: "这是用于长文阅读位置验证的合成文字，没有调用语音识别或外部模型。", count: 12))
        }
        return (try await archive.commitTranscript(ticket: ticket, spans: spans), writer)
    }

    private func readingScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 200,
           scroll.contentSize.height > scroll.bounds.height * 3 { return scroll }
        for child in view.subviews { if let result = readingScroll(in: child) { return result } }
        return nil
    }

    private func waitForReadingCondition(in window: UIWindow, stage: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if !condition() {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let screenshot = XCTAttachment(image: image)
            screenshot.name = "reading-failed-\(stage)"; screenshot.lifetime = .keepAlways; add(screenshot)
            func scrollDescription(_ view: UIView) -> [String] {
                let own: [String]
                if let scroll = view as? UIScrollView {
                    own = ["\(type(of: scroll)) id=\(scroll.accessibilityIdentifier ?? "nil") bounds=\(scroll.bounds) content=\(scroll.contentSize) offset=\(scroll.contentOffset) inset=\(scroll.adjustedContentInset)"]
                } else { own = [] }
                return own + view.subviews.flatMap(scrollDescription)
            }
            let hierarchy = XCTAttachment(string: scrollDescription(window).joined(separator: "\n"))
            hierarchy.name = "reading-scrolls-\(stage)"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        let satisfied = condition()
        XCTAssertTrue(satisfied, "The actual scroll layout/anchor must settle within the bounded wait (\(stage)).")
        // Do not run later restoration assertions with an invalid initial anchor.
        if !satisfied { throw ReadingWaitFailure.unsettled(stage) }
    }

    private enum ReadingWaitFailure: Error { case unsettled(String) }

    private enum ReadingNavigationMode { case replaceController, sameStack }

    @MainActor @Observable
    fileprivate final class ReadingNavigationPath {
        var path: [Int] = []
    }

    @MainActor
    private struct ReadingNavigationContainer<Destination: View>: View {
        let navigation: ReadingNavigationPath
        let homeVisibility: @MainActor (Bool) -> Void
        let homeGeometry: @MainActor (CGRect) -> Void
        let destination: @MainActor (Int) -> Destination

        var body: some View {
            @Bindable var navigation = navigation
            NavigationStack(path: $navigation.path) {
                Text("阅读导航首页")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("reading.navigation.home")
                    .onAppear { homeVisibility(true) }
                    .onDisappear { homeVisibility(false) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { homeGeometry($0) }
                    .navigationDestination(for: Int.self) { route in destination(route) }
            }
        }
    }

    @MainActor
    private final class ReadingViewLifetime {
        weak var archive: ArchiveStore?
        weak var model: LibraryModel?
        weak var playback: AudioPlaybackController?
        weak var window: UIWindow?
        var hasOwners: Bool { archive != nil || model != nil || playback != nil }
        var description: String { "archive=\(archive != nil), model=\(model != nil), playback=\(playback != nil), window=\(window != nil)" }
    }

    func testSourceNavigationRefreshesLoadedRecordingAndRejectsDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSourceNavigation-\(UUID())")
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let id = UUID()
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input"),
            sessionID: id, epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "source-navigation-fixture",
            sourceKind: .fixture, wallClockAnchor: .now, timezoneOffset: 0)
        _ = try writer.append([Int16](repeating: 0, count: 1600))
        let chunk = try XCTUnwrap(writer.finish())
        _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
        let claimed = try await archive.claimAnalysisJob(configurationHash: "source-navigation")
        let ticket = try XCTUnwrap(claimed)
        let original = try await archive.commitTranscript(ticket: ticket, spans: [
            TranscriptSpan(chunkID: ticket.chunkID, frames: try FrameRange(start: 0, count: 1600), text: "原始正文")
        ])
        let model = LibraryModel(archive: archive)
        await model.refresh()
        let span = try XCTUnwrap(original.spans.first)
        let revised = try await archive.reviseTranscript(sessionID: id, expectedVersion: original.version, spans: [
            TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: "已经修订的正文")
        ])
        XCTAssertEqual(model.recording(id)?.transcriptVersion, original.version)
        try await model.ensureRecording(id)
        XCTAssertEqual(model.recording(id)?.transcriptVersion, revised.version)
        XCTAssertEqual(model.recordings.count, 1)
        _ = try await archive.deleteSession(id: id)
        do { try await model.ensureRecording(id); XCTFail("Deleted recordings must not be reopened from source navigation") }
        catch { XCTAssertEqual(error as? ArchiveError, .sessionDeleted(id)) }
    }

    func testOlderRecordingsStayVisibleAfterRefreshAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPages-\(UUID())", isDirectory: true)
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        var ids = Set<UUID>()
        for _ in 0..<51 {
            let session = UUID()
            ids.insert(session)
            var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("fixture-\(session)"),
                sessionID: session, epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "pagination-fixture",
                sourceKind: .fixture, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000), timezoneOffset: 0)
            _ = try writer.append([Int16](repeating: 0, count: 1600))
            let output = try writer.finish()
            let chunk = try XCTUnwrap(output)
            let item = try archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
            _ = try await archive.commitReceivedChunk(item)
        }
        let model = LibraryModel(archive: archive)
        await model.refresh()
        XCTAssertEqual(model.recordings.count, 50)
        XCTAssertTrue(model.hasMoreRecordings)
        await model.loadMoreRecordings()
        XCTAssertEqual(Set(model.recordings.map(\.id)), ids)
        XCTAssertFalse(model.hasMoreRecordings)
        await model.refresh()
        XCTAssertEqual(Set(model.recordings.map(\.id)), ids, "Refresh must preserve the number of visible pages.")

        let deleted = try XCTUnwrap(model.recordings.last?.id)
        _ = try await archive.deleteSession(id: deleted)
        model.removeCachedRecording(deleted)
        await model.refresh()
        XCTAssertEqual(Set(model.recordings.map(\.id)), ids.subtracting([deleted]))
        XCTAssertFalse(model.hasMoreRecordings)
        XCTAssertNil(model.failure)

        let evidence = XCTAttachment(string: "Pagination uses synthetic silent PCM without ASR. Archive: \(root.path)")
        evidence.name = "library-pagination-directory"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
    func testSearchFindsUnloadedRecordingAndRefreshRejectsRevisedOrDeletedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSearch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        var oldSession: UUID?
        var oldDocument: TranscriptDocument?
        for index in 0..<51 {
            let session = UUID()
            var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input-\(index)"),
                sessionID: session, epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "search-fixture",
                sourceKind: .fixture, wallClockAnchor: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)), timezoneOffset: 0)
            _ = try writer.append([Int16](repeating: 0, count: 1600))
            let chunk = try XCTUnwrap(writer.finish())
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope))
            let claimed = try await archive.claimAnalysisJob(configurationHash: "search")
            let ticket = try XCTUnwrap(claimed)
            let document = try await archive.commitTranscript(ticket: ticket, spans: [
                TranscriptSpan(chunkID: ticket.chunkID, frames: try FrameRange(start: 0, count: 1600),
                               text: index == 0 ? "旧档唯一关键词" : "普通录音\(index)")
            ])
            if index == 0 { oldSession = session; oldDocument = document }
        }
        let id = try XCTUnwrap(oldSession), document = try XCTUnwrap(oldDocument)
        let model = LibraryModel(archive: archive)
        await model.refresh()
        XCTAssertEqual(model.recordings.count, 50)
        XCTAssertFalse(model.recordings.contains { $0.id == id })
        await model.search("唯一关键词")
        XCTAssertNil(model.searchFailure)
        XCTAssertEqual(model.searchResults.map { $0.recording.id }, [id])
        XCTAssertEqual(model.recording(id)?.transcriptVersion, document.version)
        XCTAssertEqual(model.recordings.count, 50, "Searching must not replace the visible pagination window.")
        let original = try XCTUnwrap(document.spans.first)
        _ = try await archive.reviseTranscript(sessionID: id, expectedVersion: document.version, spans: [
            TranscriptSpan(id: original.id, chunkID: original.chunkID, frames: original.frames, text: "修订后的关键词")
        ])
        await model.refresh()
        await model.search("唯一关键词")
        XCTAssertTrue(model.searchResults.isEmpty)
        await model.search("修订后的关键词")
        XCTAssertEqual(model.searchResults.count, 1)
        _ = try await archive.deleteSession(id: id)
        model.removeCachedRecording(id)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.recording(id))
        await model.search("修订后的关键词")
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertNil(model.searchFailure)
    }

}
