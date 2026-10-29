import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
@testable import MoMoLink
@preconcurrency import WatchConnectivity
@testable import MoMoAgent

@MainActor
final class PhoneReceiveControlFailureTests: XCTestCase {
    func testStatusRequestRepliesWithCommittedPhoneCapabilitiesWithoutAReverseSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoStatusReply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: device)
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in },
            statusReplyProvider: { _ in try await archive.phoneStatus(sourceBuild: "status-reply-test", refreshObservation: true) })
        // An inactive SDK session cannot initiate a reverse send. This delegate reply must still work.
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            transport.session(WCSession.default, didReceiveMessage: ["status_request": true]) { reply in
                guard let data = reply["status_snapshot"] as? Data else {
                    continuation.resume(throwing: LinkError.invalidMetadata); return
                }
                continuation.resume(returning: data)
            }
        }
        let snapshot = try LinkWireFormat.statusSnapshot(["protocol_version": 1, "status_snapshot": data])
        XCTAssertEqual(snapshot.sourceDeviceID, device)
        XCTAssertEqual(snapshot.sourceStoreInstanceID, archive.libraryInstanceID)
        guard case .phone(let phone) = snapshot.payload else { XCTFail("Expected phone status"); return }
        XCTAssertEqual(phone.audioBlockVersion, AudioBlock.version)
        XCTAssertEqual(snapshot.sourceBuild, "status-reply-test")
    }

    func testOnlyFreshSelectedBindingSupersedesReceiverConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoReceiverBinding-\(UUID())")
        let device = UUID(), source = UUID(), store = UUID()
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("archive"), receiverDeviceID: device)
        let controls = try ControlInbox(directory: root.appendingPathComponent("controls"))
        let identity = ReceiverIdentity(messageID: archive.libraryInstanceID, receiverDeviceID: device,
                                        libraryInstanceID: archive.libraryInstanceID)
        let coordinator = PhoneReceiveCoordinator(archive: archive, controls: controls, identity: identity)
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.genericError.rawValue))
        var banner: String?
        coordinator.onSyncFailure = { banner = $0 }
        let message = ControlMessage.receiverIdentity(identity)
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNotNil(banner)
        let directory = root.appendingPathComponent("selected-watch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = SelectedWatchEventClock()
        await coordinator.receive(.selectedWatchChanged(clock.select(activation: .activated, peerState: .available,
                                                                    directoryURL: directory)))
        let payload = StatusPayload.watch(try WatchCaptureStatus(receiverLibraryInstanceID: archive.libraryInstanceID,
            sessionID: nil, epochID: nil, activity: .idle, capturedDuration: 0, sealedDuration: 0,
            pendingChunkCount: 0, pendingBytes: 0))
        let cached = try StatusSnapshot(sourceDeviceID: source, sourceBuild: "binding-test", sourceStoreInstanceID: store,
                                       revision: 1, payload: payload)
        await coordinator.receive(.selectedWatchStatusReceived(cached, origin: .restoredApplicationContext,
                                                               context: clock.receive()))
        XCTAssertNotNil(banner, "A restored report cannot establish the current receiver binding.")
        let fresh = try StatusSnapshot(sourceDeviceID: source, sourceBuild: "binding-test", sourceStoreInstanceID: store,
                                      revision: 2, payload: payload)
        await coordinator.receive(.selectedWatchStatusReceived(fresh, origin: .applicationContextCallback,
                                                               context: clock.receive()))
        XCTAssertNil(banner)
        let other = ControlMessage.deleteSession(try DeleteSession(sessionID: UUID(), generation: 1))
        await coordinator.receive(.controlTransportFinished(message: other, failure: failure))
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNotNil(banner, "Receiver binding cannot complete another command.")
    }

    func testReachableControlUsesOneRouteAndGeneralReplayRetainsCustody() throws {
        let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        let first = try transport.reserveControlRoutes(message, outstanding: [], isReachable: true, now: 100)
        XCTAssertEqual(first.background, .deferred)
        XCTAssertEqual(first.interactive, .submitted)
        let inflight = try transport.reserveControlRoutes(message, outstanding: [], isReachable: true, now: 101)
        XCTAssertEqual(inflight.background, .deferred)
        XCTAssertEqual(inflight.interactive, .alreadySubmitted)
        transport.finishInteractive(message, failed: false)
        transport.allowControlReplay()
        let confirmed = try transport.reserveControlRoutes(message, outstanding: [], isReachable: true, now: 102)
        XCTAssertEqual(confirmed.background, .alreadySubmitted)
        XCTAssertEqual(confirmed.interactive, .alreadySubmitted)
    }

    func testImmediateFailureAllowsOneBackgroundCopyWhileThatRouteCoolsDown() throws {
        let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        let first = try transport.reserveControlRoutes(message, outstanding: [], isReachable: true)
        XCTAssertEqual(first.background, .deferred)
        XCTAssertEqual(first.interactive, .submitted)
        transport.finishInteractive(message, failed: true)
        let fallback = try transport.reserveControlRoutes(message, outstanding: [], isReachable: true)
        XCTAssertEqual(fallback.background, .submitted)
        XCTAssertEqual(fallback.interactive, .deferred)
        let repeated = try transport.reserveControlRoutes(message, outstanding: [message], isReachable: true)
        XCTAssertEqual(repeated.background, .alreadySubmitted)
        XCTAssertEqual(repeated.interactive, .deferred)
    }

    func testFullImmediateWindowDoesNotSpillHealthyTrafficIntoBackground() throws {
        let messages = (0..<5).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID())) }
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        for message in messages.prefix(4) {
            let result = try transport.reserveControlRoutes(message, outstanding: [], isReachable: true)
            XCTAssertEqual(result.background, .deferred)
            XCTAssertEqual(result.interactive, .submitted)
        }
        let blocked = try transport.reserveControlRoutes(messages[4], outstanding: [], isReachable: true)
        XCTAssertEqual(blocked.background, .deferred)
        XCTAssertEqual(blocked.interactive, .deferred)
    }

    func testLateIdentityFailureCannotReplaceAConfirmedDurableInboxReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoControlFailure-\(UUID())")
        let receiver = UUID()
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("archive"), receiverDeviceID: receiver)
        let controls = try ControlInbox(directory: root.appendingPathComponent("controls"))
        let identity = ReceiverIdentity(messageID: UUID(), receiverDeviceID: receiver, libraryInstanceID: archive.libraryInstanceID)
        let coordinator = PhoneReceiveCoordinator(archive: archive, controls: controls, identity: identity)
        let transport = try WatchConnectivityTransport(preserveFile: { _, _ in }, preserveControl: { _ in }, event: { _ in })
        coordinator.attach(transport)
        let message = ControlMessage.receiverIdentity(identity)
        let failure = TransportFailure(NSError(domain: WCErrorDomain, code: WCError.Code.genericError.rawValue))
        var banner: String?
        coordinator.onSyncFailure = { banner = $0 }
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNotNil(banner)
        // This boundary runs only after the peer replies that its durable inbox saved this exact command.
        transport.finishInteractive(message, failed: false)
        await coordinator.receive(.controlTransportFinished(message: message, failure: failure))
        XCTAssertNil(banner)
        let unrelated = ControlMessage.deleteSession(try DeleteSession(sessionID: UUID(), generation: 1))
        await coordinator.receive(.controlTransportFinished(message: unrelated, failure: failure))
        XCTAssertNotNil(banner, "An identity reply cannot acknowledge another command.")
    }
}
