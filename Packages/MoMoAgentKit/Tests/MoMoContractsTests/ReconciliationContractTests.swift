import Foundation
import Testing
import MoMoContracts

@Test func fullReceiptPageFitsControlBudgetAndKeepsRequestIdentity() throws {
    let receiver = UUID(), library = UUID()
    let items = try (0..<ReconciliationLimits.maximumItems).map { index in
        try ReconcileChunkIdentity(sessionID: UUID(), chunkID: UUID(),
            audioSHA256: ContentHash.sha256(Data("audio-\(index)".utf8)),
            manifestSHA256: ContentHash.sha256(Data("manifest-\(index)".utf8)))
    }
    let request = try ReconcileRequest(sourceDeviceID: UUID(), receiverDeviceID: receiver, libraryInstanceID: library, items: items)
    let results = try items.map { item in
        try ReconcileResult(chunkID: item.chunkID, state: .received(Receipt(receiverDeviceID: receiver,
            libraryInstanceID: library, chunkID: item.chunkID, audioSHA256: item.audioSHA256, manifestSHA256: item.manifestSHA256)))
    }
    let response = try ReconcileResponse(requestID: request.messageID, requestSHA256: request.requestSHA256,
        sourceDeviceID: request.sourceDeviceID, receiverDeviceID: receiver, libraryInstanceID: library, results: results)
    #expect(try response.matches(request))
    for message in [ControlMessage.reconcileRequest(request), .reconcileResponse(response)] {
        let data = try WireJSON.encode(message)
        #expect(data.count <= 16 * 1024)
        #expect(try WireJSON.decode(ControlMessage.self, from: data) == message)
    }
    #expect(try WireJSON.decode(ReconcileRequest.self, from: WireJSON.encode(request)).requestSHA256 == request.requestSHA256)
}

@Test func reconciliationRejectsDuplicatesOverflowAndMalformedDecodedHashes() throws {
    let item = try ReconcileChunkIdentity(sessionID: UUID(), chunkID: UUID(), audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))
    let oversized = try (0...ReconciliationLimits.maximumItems).map { _ in
        try ReconcileChunkIdentity(sessionID: item.sessionID, chunkID: UUID(),
            audioSHA256: item.audioSHA256, manifestSHA256: item.manifestSHA256)
    }
    for items in [[], [item, item], oversized] {
        #expect(throws: ContractError.self) {
            try ReconcileRequest(sourceDeviceID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID(), items: items)
        }
    }
    var object = try #require(JSONSerialization.jsonObject(with: WireJSON.encode(item)) as? [String: Any])
    object["manifestSHA256"] = "not-a-hash"
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ContractError.self) { try WireJSON.decode(ReconcileChunkIdentity.self, from: data) }
}

@Test func responseCannotSubstituteHashesMembersOrDeletionScope() throws {
    let item = try ReconcileChunkIdentity(sessionID: UUID(), chunkID: UUID(), audioSHA256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))
    let request = try ReconcileRequest(sourceDeviceID: UUID(), receiverDeviceID: UUID(), libraryInstanceID: UUID(), items: [item])
    let forged = try Receipt(receiverDeviceID: request.receiverDeviceID, libraryInstanceID: request.libraryInstanceID,
        chunkID: item.chunkID, audioSHA256: item.audioSHA256, manifestSHA256: String(repeating: "c", count: 64))
    for result in [try ReconcileResult(chunkID: item.chunkID, state: .received(forged)),
                   try ReconcileResult(chunkID: UUID(), state: .unknown),
                   try ReconcileResult(chunkID: item.chunkID, state: .deleted(DeleteSession(sessionID: UUID(), generation: 1)))] {
        let response = try ReconcileResponse(requestID: request.messageID, requestSHA256: request.requestSHA256,
            sourceDeviceID: request.sourceDeviceID, receiverDeviceID: request.receiverDeviceID,
            libraryInstanceID: request.libraryInstanceID, results: [result])
        #expect(try !response.matches(request))
    }
}

@Test func statusValidatesRoleLibraryAndActualSampleFieldsOnDecode() throws {
    #expect(throws: ContractError.self) {
        try WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: UUID(), epochID: nil, activity: .recording,
            capturedDuration: 0, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0)
    }
    #expect(throws: ContractError.self) {
        try WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: UUID(), epochID: nil, activity: .paused,
            capturedDuration: .infinity, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0)
    }
    let library = UUID()
    let payload = StatusPayload.phone(try PhoneArchiveStatus(libraryInstanceID: library, recordingCount: 0, pendingAnalysisCount: 0, pendingReceiptCount: 0))
    #expect(throws: ContractError.self) {
        try StatusSnapshot(sourceDeviceID: UUID(), sourceBuild: "test", sourceStoreInstanceID: UUID(), revision: 1, payload: payload)
    }
    let snapshot = try StatusSnapshot(sourceDeviceID: UUID(), sourceBuild: "test", sourceStoreInstanceID: library,
        revision: 1, sampledAt: Date(timeIntervalSince1970: 1), payload: payload)
    var object = try #require(JSONSerialization.jsonObject(with: WireJSON.encode(snapshot)) as? [String: Any])
    object["revision"] = 0
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ContractError.self) { try WireJSON.decode(StatusSnapshot.self, from: data) }
}

@Test func receiptBatchesFitControlBudgetPreserveDeterministicIdentityAndRejectInvalidItems() throws {
    let receiver = UUID(), library = UUID()
    let receipts = try (0..<ReceiptBatchLimits.maximumItems).map { index in
        try Receipt(
            receiverDeviceID: receiver,
            libraryInstanceID: library,
            chunkID: UUID(),
            audioSHA256: ContentHash.sha256(Data("audio-\(index)".utf8)),
            manifestSHA256: ContentHash.sha256(Data("manifest-\(index)".utf8))
        )
    }
    let batchA = try ReceiptBatch(items: receipts)
    let batchB = try ReceiptBatch(items: receipts)
    #expect(batchA.messageID == batchB.messageID)
    #expect(try ControlMessage.packReceipts([receipts[0]]) == .receipt(receipts[0]))
    #expect(try ControlMessage.packReceipts(receipts) == .receiptBatch(batchA))

    let applied = receipts.map { ReceiptApplied(receipt: $0) }
    let appliedBatchA = try ReceiptAppliedBatch(items: applied)
    let appliedBatchB = try ReceiptAppliedBatch(items: applied)
    #expect(appliedBatchA.messageID == appliedBatchB.messageID)
    #expect(try ControlMessage.packReceiptsApplied([applied[0]]) == .receiptApplied(applied[0]))
    #expect(try ControlMessage.packReceiptsApplied(applied) == .receiptAppliedBatch(appliedBatchA))

    for message in [ControlMessage.receiptBatch(batchA), .receiptAppliedBatch(appliedBatchA)] {
        let encoded = try WireJSON.encode(message)
        #expect(encoded.count <= 6_800)
        #expect(try WireJSON.decode(ControlMessage.self, from: encoded) == message)
    }

    #expect(throws: ContractError.self) { _ = try ReceiptBatch(items: []) }
    #expect(throws: ContractError.self) { _ = try ReceiptBatch(items: [receipts[0], receipts[0]]) }
    let wrongLibrary = try Receipt(
        receiverDeviceID: receiver,
        libraryInstanceID: UUID(),
        chunkID: UUID(),
        audioSHA256: receipts[0].audioSHA256,
        manifestSHA256: receipts[0].manifestSHA256
    )
    #expect(throws: ContractError.self) { _ = try ReceiptBatch(items: [receipts[0], wrongLibrary]) }
}
