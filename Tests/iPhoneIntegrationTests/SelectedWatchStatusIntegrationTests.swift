import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoLink
import MoMoRecording
@testable import MoMoAgent

@MainActor
final class SelectedWatchStatusIntegrationTests: XCTestCase {
    func testSwitchAndReorderedCallbacksKeepOldWatchInHistoryOnly() async throws {
        let fixture = try await SelectedStatusFixture()
        let receiver = fixture.coordinator()
        let library = LibraryModel(archive: fixture.archive)
        receiver.onCurrentWatchStatusChanged = { library.updateCurrentWatchStatus($0) }
        let clock = SelectedWatchEventClock()
        let aSelection = clock.select(activation: .activated, peerState: .available, directoryURL: fixture.a.directory)
        await receiver.receive(.selectedWatchChanged(aSelection))
        let a = try fixture.snapshot(fixture.a, revision: 1, sampledAt: 100)
        await receiver.receive(.selectedWatchStatusReceived(a, origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertEqual(library.watchStatus?.snapshot, a)

        // Capture at the delegate boundary, then deliberately deliver after the new Watch.
        let lateAContext = clock.receive()
        let lateA = try fixture.snapshot(fixture.a, revision: 2, sampledAt: 900)
        let inactive = clock.select(activation: .inactive, peerState: .available, directoryURL: fixture.a.directory)
        await receiver.receive(.selectedWatchChanged(inactive))
        XCTAssertNil(library.watchStatus)
        let drainingA = clock.receive()
        let bSelection = clock.select(activation: .activated, peerState: .available, directoryURL: fixture.b.directory)
        await receiver.receive(.selectedWatchChanged(bSelection))
        XCTAssertNil(library.watchStatus, "An empty selected scope must not reuse the archive's global latest report")
        let b = try fixture.snapshot(fixture.b, revision: 8, sampledAt: 200)
        await receiver.receive(.selectedWatchStatusReceived(b, origin: .applicationContextCallback, context: clock.receive()))
        await receiver.receive(.selectedWatchStatusReceived(lateA, origin: .applicationContextCallback, context: lateAContext))
        await receiver.receive(.selectedWatchChanged(aSelection))
        await receiver.receive(.selectedWatchStatusReceived(try fixture.snapshot(fixture.a, revision: 3, sampledAt: 999),
            origin: .applicationContextCallback, context: drainingA))

        let global = try await fixture.archive.latestWatchStatus()
        XCTAssertEqual(global?.snapshot.sourceDeviceID, fixture.a.source)
        await library.refresh()
        XCTAssertEqual(receiver.currentWatchStatus?.snapshot, b)
        XCTAssertEqual(library.watchStatus?.snapshot, b, "Refresh must never replace the selected scope with global history")
        XCTAssertEqual(try SelectedWatchStatusFile.read(directory: fixture.b.directory,
            libraryID: fixture.archive.libraryInstanceID), b)
        XCTAssertEqual(try SelectedWatchStatusFile.read(directory: fixture.a.directory,
            libraryID: fixture.archive.libraryInstanceID), a, "Late callbacks cannot write a previous selection's cache")
        let receipts = try await fixture.archive.pendingReceipts()
        let recordings = try await fixture.archive.recordings()
        XCTAssertEqual(receipts.count, fixture.receipts.count)
        XCTAssertTrue(fixture.receipts.allSatisfy(receipts.contains))
        XCTAssertEqual(Set(recordings.map(\.id)), Set([fixture.a.session, fixture.b.session]))
    }

    func testRestartRestoresOnlySelectedDirectoryAndRequiresNewRevisionForFreshness() async throws {
        let fixture = try await SelectedStatusFixture()
        let first = fixture.coordinator()
        let firstClock = SelectedWatchEventClock()
        let a = try fixture.snapshot(fixture.a, revision: 10, sampledAt: 900)
        let b = try fixture.snapshot(fixture.b, revision: 5, sampledAt: 200)
        await first.receive(.selectedWatchChanged(firstClock.select(activation: .activated,
            peerState: .available, directoryURL: fixture.a.directory)))
        await first.receive(.selectedWatchStatusReceived(a, origin: .applicationContextCallback, context: firstClock.receive()))
        await first.receive(.selectedWatchChanged(firstClock.select(activation: .activated,
            peerState: .available, directoryURL: fixture.b.directory)))
        await first.receive(.selectedWatchStatusReceived(b, origin: .applicationContextCallback, context: firstClock.receive()))

        let reopened = try ArchiveStore(rootURL: fixture.archive.rootURL, receiverDeviceID: fixture.receiver)
        let receiver = fixture.coordinator(archive: reopened)
        let library = LibraryModel(archive: reopened)
        receiver.onCurrentWatchStatusChanged = { library.updateCurrentWatchStatus($0) }
        let clock = SelectedWatchEventClock()
        await library.refresh()
        XCTAssertNil(library.watchStatus, "Opening the archive without an activated selected scope is not live status")
        await receiver.receive(.selectedWatchChanged(clock.select(activation: .activated,
            peerState: .available, directoryURL: fixture.b.directory)))
        XCTAssertEqual(library.watchStatus?.snapshot, b)
        XCTAssertEqual(library.watchStatus?.restored, true)
        XCTAssertNil(library.watchStatus?.observedAt)
        await receiver.receive(.selectedWatchStatusReceived(b, origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertEqual(library.watchStatus?.restored, true, "An identical cached context cannot acquire fresh arrival time")
        let newerB = try fixture.snapshot(fixture.b, revision: 6, sampledAt: 201)
        await receiver.receive(.selectedWatchStatusReceived(newerB, origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertEqual(library.watchStatus?.snapshot, newerB)
        XCTAssertEqual(library.watchStatus?.restored, false)
        XCTAssertNotNil(library.watchStatus?.observedAt)

        let unknown = fixture.root.appendingPathComponent("unknown-selected-watch", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        await receiver.receive(.selectedWatchChanged(clock.select(activation: .activated,
            peerState: .available, directoryURL: unknown)))
        await library.refresh()
        XCTAssertNil(library.watchStatus)
        await receiver.receive(.selectedWatchChanged(clock.select(activation: .activated,
            peerState: .available, directoryURL: fixture.a.directory)))
        XCTAssertEqual(library.watchStatus?.snapshot, a)
        XCTAssertEqual(library.watchStatus?.restored, true)
        await receiver.receive(.selectedWatchChanged(clock.select(activation: .inactive,
            peerState: .notPaired, directoryURL: fixture.a.directory)))
        XCTAssertNil(library.watchStatus)
        await receiver.receive(.selectedWatchChanged(clock.select(activation: .activated,
            peerState: .available, directoryURL: nil)))
        XCTAssertNil(library.watchStatus)
    }

    func testRetiredErrorsUnscopedReportsAndDeletedRecordingsCannotReplaceCurrentStatus() async throws {
        let fixture = try await SelectedStatusFixture()
        let receiver = fixture.coordinator()
        let clock = SelectedWatchEventClock()
        var failure: String?
        receiver.onStatusFailure = { failure = $0 }
        _ = clock.select(activation: .activated, peerState: .available, directoryURL: fixture.a.directory)
        let oldContext = clock.receive()
        await receiver.receive(.selectedWatchChanged(clock.select(activation: .activated,
            peerState: .available, directoryURL: fixture.b.directory)))
        let b = try fixture.snapshot(fixture.b, revision: 4, sampledAt: 200)
        await receiver.receive(.selectedWatchStatusReceived(b, origin: .applicationContextCallback, context: clock.receive()))
        await receiver.receive(.selectedWatchStatusReceived(try fixture.snapshot(fixture.a, revision: 1,
            sampledAt: 900, libraryID: UUID()), origin: .applicationContextCallback, context: oldContext))
        await receiver.receive(.selectedWatchStatusFailed(TransportFailure(LinkError.invalidMetadata), context: oldContext))
        XCTAssertNil(failure, "A retired Watch's error must not label the selected Watch as broken")
        await receiver.receive(.statusReceived(try fixture.snapshot(fixture.a, revision: 2, sampledAt: 999),
            origin: .applicationContextCallback))
        XCTAssertEqual(receiver.currentWatchStatus?.snapshot, b, "Legacy unscoped status remains history only")
        await receiver.receive(.statusReceived(try fixture.snapshot(fixture.a, revision: 3, sampledAt: 999,
            libraryID: UUID()), origin: .applicationContextCallback))
        XCTAssertNil(failure, "An unscoped error cannot be attributed to the selected Watch")
        await receiver.receive(.selectedWatchStatusReceived(try fixture.snapshot(fixture.b, revision: 5,
            sampledAt: 201, libraryID: UUID()), origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertNotNil(failure)
        XCTAssertEqual(receiver.currentWatchStatus?.snapshot, b)
        let selectedFailure = failure
        await receiver.receive(.statusReceived(try fixture.snapshot(fixture.a, revision: 2, sampledAt: 999),
            origin: .applicationContextCallback))
        XCTAssertEqual(failure, selectedFailure, "Unscoped success cannot dismiss a selected-Watch failure")
        XCTAssertEqual(try SelectedWatchStatusFile.read(directory: fixture.b.directory,
            libraryID: fixture.archive.libraryInstanceID), b)

        _ = try await fixture.archive.deleteSession(id: fixture.b.session)
        receiver.clearDeletedStatus(sessionID: fixture.b.session)
        XCTAssertNil(receiver.currentWatchStatus)
        await receiver.receive(.selectedWatchStatusReceived(b, origin: .applicationContextCallback, context: clock.receive()))
        XCTAssertNil(receiver.currentWatchStatus, "A deleted session cannot return through a late report")
        let reopenedReceiver = fixture.coordinator()
        let reopenedClock = SelectedWatchEventClock()
        await reopenedReceiver.receive(.selectedWatchChanged(reopenedClock.select(activation: .activated,
            peerState: .available, directoryURL: fixture.b.directory)))
        XCTAssertNil(reopenedReceiver.currentWatchStatus, "The same deletion gate applies to the directory cache")
        let aHistorical = try await fixture.archive.watchStatus(sessionID: fixture.a.session)
        XCTAssertEqual(aHistorical?.snapshot.revision, 2)
        let receipts = try await fixture.archive.pendingReceipts()
        XCTAssertEqual(receipts, [fixture.receipts[0]])
    }
}

@MainActor
private struct SelectedStatusFixture {
    struct Watch {
        let directory: URL
        let source = UUID(), store = UUID(), session = UUID(), epoch = UUID()
    }
    let root: URL
    let archive: ArchiveStore
    let controls: ControlInbox
    let receiver = UUID()
    let a: Watch
    let b: Watch
    let receipts: [Receipt]

    init() async throws {
        // The hosted runner owns removal after coordinators/SQLite have released these isolated files.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoSelectedStatus-\(UUID())")
        archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: receiver)
        controls = try ControlInbox(directory: root.appendingPathComponent("controls"))
        a = Watch(directory: root.appendingPathComponent("selected-a", isDirectory: true))
        b = Watch(directory: root.appendingPathComponent("selected-b", isDirectory: true))
        var receipts: [Receipt] = []
        for watch in [a, b] {
            try FileManager.default.createDirectory(at: watch.directory, withIntermediateDirectories: true)
            var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("capture-\(watch.source)"),
                sessionID: watch.session, epochID: watch.epoch, sourceDeviceID: watch.source,
                sourceBuild: "selected-status-test", sourceKind: .watch,
                wallClockAnchor: Date(timeIntervalSince1970: 1), timezoneOffset: 0)
            _ = try writer.append([Int16](repeating: 0, count: 1600))
            let chunk = try XCTUnwrap(writer.finish())
            let item = try archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
            guard case .accepted(let receipt) = try await archive.commitReceivedChunk(item) else {
                throw ArchiveError.invalidInbox
            }
            receipts.append(receipt)
        }
        self.receipts = receipts
    }

    func coordinator(archive: ArchiveStore? = nil) -> PhoneReceiveCoordinator {
        let archive = archive ?? self.archive
        return PhoneReceiveCoordinator(archive: archive, controls: controls,
            identity: ReceiverIdentity(messageID: receiver, receiverDeviceID: receiver,
                libraryInstanceID: archive.libraryInstanceID))
    }

    func snapshot(_ watch: Watch, revision: Int64, sampledAt: Double, libraryID: UUID? = nil) throws -> StatusSnapshot {
        try StatusSnapshot(sourceDeviceID: watch.source, sourceBuild: "selected-status-test",
            sourceStoreInstanceID: watch.store, revision: revision, sampledAt: Date(timeIntervalSince1970: sampledAt),
            payload: .watch(WatchCaptureStatus(receiverLibraryInstanceID: libraryID ?? archive.libraryInstanceID,
                sessionID: watch.session, epochID: watch.epoch, activity: .recording,
                capturedDuration: 30, sealedDuration: 0.1, pendingChunkCount: 1, pendingBytes: 3200,
                lastSampleFrame: 480_000, timebaseHz: 16_000, lastSampleAge: 0.01)))
    }
}
