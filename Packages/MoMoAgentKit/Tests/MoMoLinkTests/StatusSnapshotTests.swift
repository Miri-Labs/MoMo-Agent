import Foundation
import Testing
import MoMoContracts
import MoMoLink

struct StatusSnapshotTests {
    @Test func backgroundAndViewingRequestsUseExplicitIntentOutsideDurableControls() throws {
        let passive = LinkWireFormat.statusRequestMetadata()
        #expect(passive.count == 1, "Legacy peers must receive the original one-field request.")
        #expect(try LinkWireFormat.statusRequestViewing(passive) == false)
        let viewing = LinkWireFormat.statusRequestMetadata(viewing: true)
        #expect(try LinkWireFormat.statusRequestViewing(viewing) == true)
        #expect(try LinkWireFormat.statusRequestViewing(["status_request": true, "viewing": false]) == false)
        #expect(try LinkWireFormat.statusRequestViewing(["control": Data()]) == nil)
        let invalidRequests: [[String: Any]] = [["status_request": false], ["status_request": true, "viewing": "true"],
                                              ["status_request": true, "control": Data()]]
        for invalid in invalidRequests {
            #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.statusRequestViewing(invalid) }
        }
        #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.controlMessage(viewing) }
        #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.statusSnapshot(viewing) }
    }

    @Test func audioBatchCapabilityIsOptionalForOlderStatusSnapshots() throws {
        let legacy = try WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: nil, epochID: nil,
            activity: .idle, capturedDuration: 0, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0)
        let legacyData = try WireJSON.encode(legacy)
        let decodedLegacy = try WireJSON.decode(WatchCaptureStatus.self, from: legacyData)
        #expect(decodedLegacy.audioBatchVersion == nil)
        let capable = try WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: nil, epochID: nil,
            activity: .idle, capturedDuration: 0, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0,
            audioBatchVersion: 1)
        #expect(try WireJSON.decode(WatchCaptureStatus.self, from: WireJSON.encode(capable)) == capable)
        var invalid = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        invalid["audioBatchVersion"] = 0
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: ContractError.invalidField("watch_status")) {
            try WireJSON.decode(WatchCaptureStatus.self, from: invalidData)
        }
    }

    @Test func bothRolesRoundTripWithoutEnteringTheDurableControlChannel() throws {
        let watch = try watchSnapshot()
        let library = UUID()
        let phone = try StatusSnapshot(sourceDeviceID: UUID(), sourceBuild: "status-test",
            sourceStoreInstanceID: library, revision: 1, sampledAt: Date(timeIntervalSince1970: 100),
            payload: .phone(PhoneArchiveStatus(libraryInstanceID: library, recordingCount: 3,
                pendingAnalysisCount: 2, pendingReceiptCount: 1)))
        for snapshot in [watch, phone] {
            let metadata = try LinkWireFormat.statusMetadata(snapshot)
            #expect(try LinkWireFormat.statusSnapshot(metadata) == snapshot)
            #expect(metadata["control"] == nil)
            #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.controlMessage(metadata) }
        }
        #expect(watch.sourceRole == .watch)
        #expect(phone.sourceRole == .phone)
        let control = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
        #expect(throws: LinkError.invalidMetadata) {
            try LinkWireFormat.statusSnapshot(LinkWireFormat.controlMetadata(control))
        }
    }

    @Test func statusBoundaryRejectsOversizedUnknownAndInvalidPayloads() throws {
        let metadata = try LinkWireFormat.statusMetadata(watchSnapshot())
        var wrongVersion = metadata
        wrongVersion["protocol_version"] = 2
        #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.statusSnapshot(wrongVersion) }
        var extraChannel = metadata
        extraChannel["control"] = Data()
        #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.statusSnapshot(extraChannel) }
        #expect(throws: LinkError.statusSnapshotTooLarge) {
            try LinkWireFormat.statusSnapshot(["protocol_version": 1,
                "status_snapshot": Data(repeating: 32, count: LinkWireFormat.maximumStatusBytes + 1)])
        }
        let original = try #require(metadata["status_snapshot"] as? Data)
        var invalid = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        invalid["revision"] = 0
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: ContractError.invalidField("status_snapshot")) {
            try LinkWireFormat.statusSnapshot(["protocol_version": 1, "status_snapshot": invalidData])
        }
    }

    @Test func revisionWinsOverClockAndSameRevisionCannotChangeContent() throws {
        let device = UUID(), store = UUID()
        var state = LinkStatusReceiveState()
        let current = try watchSnapshot(device: device, store: store, revision: 5, sampledAt: 500)
        #expect(try state.accept(current))
        #expect(try !state.accept(current))
        #expect(try !state.accept(watchSnapshot(device: device, store: store, revision: 4, sampledAt: 900)))
        #expect(throws: LinkError.conflictingStatus(sourceDeviceID: device, sourceStoreInstanceID: store, revision: 5)) {
            try state.accept(watchSnapshot(device: device, store: store, revision: 5, sampledAt: 500, pending: 2))
        }
        #expect(try state.accept(watchSnapshot(device: device, store: store, revision: 6, sampledAt: 100)))
        #expect(try !state.accept(current))
    }

    @Test func storeInstancesAndDevicesHaveIndependentRevisionStreams() throws {
        let device = UUID(), otherDevice = UUID(), firstStore = UUID(), secondStore = UUID()
        var state = LinkStatusReceiveState()
        #expect(try state.accept(watchSnapshot(device: device, store: firstStore, revision: 90, sampledAt: 900)))
        #expect(try state.accept(watchSnapshot(device: device, store: secondStore, revision: 1, sampledAt: 100)))
        #expect(try state.accept(watchSnapshot(device: otherDevice, store: firstStore, revision: 1, sampledAt: 100)))
        #expect(try !state.accept(watchSnapshot(device: device, store: firstStore, revision: 89, sampledAt: 999)))
        #expect(try state.accept(watchSnapshot(device: device, store: secondStore, revision: 2, sampledAt: 50)))
        #expect(try !state.accept(watchSnapshot(device: otherDevice, store: firstStore, revision: 1, sampledAt: 100)))
    }

    @Test func restoredSnapshotSeedRejectsOldSystemCacheAndCanonicalReplay() throws {
        let device = UUID(), store = UUID()
        let durable = try watchSnapshot(device: device, store: store, revision: 8)
        var state = LinkStatusReceiveState()
        try state.seed(durable)
        #expect(try !state.accept(watchSnapshot(device: device, store: store, revision: 7)))
        let encoded = try WireJSON.encode(durable)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let differentlyFormatted = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
        let replay = try LinkWireFormat.statusSnapshot(["protocol_version": 1, "status_snapshot": differentlyFormatted])
        #expect(try !state.accept(replay))
        #expect(try state.accept(watchSnapshot(device: device, store: store, revision: 9)))
    }

    @Test func explicitReconcileMessagesRemainInTheBoundedControlChannel() throws {
        let request = try ReconcileRequest(sourceDeviceID: UUID(), receiverDeviceID: UUID(),
            libraryInstanceID: UUID(), items: [ReconcileChunkIdentity(sessionID: UUID(), chunkID: UUID(),
                audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))])
        let response = try ReconcileResponse(requestID: request.messageID, requestSHA256: request.requestSHA256,
            sourceDeviceID: request.sourceDeviceID, receiverDeviceID: request.receiverDeviceID,
            libraryInstanceID: request.libraryInstanceID,
            results: [ReconcileResult(chunkID: request.items[0].chunkID, state: .missing)])
        var queue = LinkControlSubmissionState()
        for message in [ControlMessage.reconcileRequest(request), .reconcileResponse(response)] {
            let metadata = try LinkWireFormat.controlMetadata(message)
            #expect(try LinkWireFormat.controlMessage(metadata) == message)
            #expect(throws: LinkError.invalidMetadata) { try LinkWireFormat.statusSnapshot(metadata) }
            #expect(try queue.reserve(message) == .submitted)
            try queue.didFinish(message, failed: false)
            #expect(try queue.reserve(message) == .alreadySubmitted)
        }
    }

    private func watchSnapshot(device: UUID = UUID(), store: UUID = UUID(), revision: Int64 = 1,
                               sampledAt: TimeInterval = 100, pending: Int = 1) throws -> StatusSnapshot {
        try StatusSnapshot(sourceDeviceID: device, sourceBuild: "status-test", sourceStoreInstanceID: store,
            revision: revision, sampledAt: Date(timeIntervalSince1970: sampledAt),
            payload: .watch(WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: nil, epochID: nil,
                activity: .idle, capturedDuration: 0, sealedDuration: 0, pendingChunkCount: pending, pendingBytes: 16)))
    }
}
