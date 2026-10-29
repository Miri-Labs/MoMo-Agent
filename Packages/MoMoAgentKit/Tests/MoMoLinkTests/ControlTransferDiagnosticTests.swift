import Foundation
import Testing
import MoMoContracts
@testable import MoMoLink

@Test func controlDiagnosticKeepsOnlyRecentResultsWithoutPrivateErrorTextOrPayload() throws {
    var diagnostic = ControlTransferDiagnostic()
    let generation = UUID(), device = UUID()
    let messages = (0..<40).map { _ in ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: device)) }
    let failure = TransportFailure(NSError(domain: "WCErrorDomain", code: 7007, userInfo: [
        NSLocalizedDescriptionKey: "private diagnostic detail",
        NSUnderlyingErrorKey: NSError(domain: "IDSServiceErrorDomain", code: 200)
    ]))
    for (index, message) in messages.enumerated() {
        diagnostic.append(message: message, generation: generation, route: .interactive, outcome: .sdkError,
            observation: .init(observedAt: Date(timeIntervalSince1970: Double(index)), activated: true, reachable: false),
            failure: failure)
    }
    #expect(diagnostic.entries.count == 32)
    #expect(diagnostic.entries.first?.messageID == messages[8].messageID)
    #expect(diagnostic.entries.last?.messageID == messages[39].messageID)
    #expect(diagnostic.entries.last?.failure?.underlyingDomain == "IDSServiceErrorDomain")
    #expect(diagnostic.entries.last?.failure?.underlyingCode == 200)
    #expect(diagnostic.failures.count == 16)
    #expect(diagnostic.failures.first?.messageID == messages[24].messageID)
    let encoded = try JSONEncoder().encode(diagnostic)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(!json.contains("private diagnostic detail"))
    #expect(!json.contains(device.uuidString), "A message's payload fields must not enter diagnostic history.")
    #expect(encoded.count < 65_536)
    let restored = try JSONDecoder().decode(ControlTransferDiagnostic.self, from: encoded)
    #expect(restored.entries.map(\.messageID) == diagnostic.entries.map(\.messageID))
    #expect(restored.failures.map(\.messageID) == diagnostic.failures.map(\.messageID))
}

@Test func controlDiagnosticRetainsFailureThroughReceiptBurstAndRestart() throws {
    let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let observation = ControlTransferDiagnostic.Observation(observedAt: Date(), activated: true, reachable: true)
    var diagnostic = ControlTransferDiagnostic()
    diagnostic.append(message: message, generation: UUID(), route: .interactive, outcome: .localDeadline,
        observation: observation, failure: TransportFailure(NSError(domain: "WCErrorDomain", code: 7012)))
    for _ in 0..<100 {
        diagnostic.append(message: message, generation: UUID(), route: .background, outcome: .sdkCompleted,
            observation: observation)
    }
    let restored = try JSONDecoder().decode(ControlTransferDiagnostic.self, from: JSONEncoder().encode(diagnostic))
    #expect(restored.entries.allSatisfy { $0.outcome == .sdkCompleted })
    #expect(restored.failures.count == 1)
    #expect(restored.failures.first?.messageID == message.messageID)
    #expect(restored.failures.first?.outcome == .localDeadline)
    #expect(restored.failures.first?.failure?.code == 7012)
}

@Test func controlDiagnosticRestoresLegacyHistoryWithoutFailureArray() throws {
    let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    var diagnostic = ControlTransferDiagnostic()
    diagnostic.append(message: message, generation: nil, route: .background, outcome: .sdkError,
        observation: .init(observedAt: Date(), activated: true, reachable: false),
        failure: TransportFailure(NSError(domain: "WCErrorDomain", code: 7001)))
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
    legacy.removeValue(forKey: "failures")
    let restored = try JSONDecoder().decode(ControlTransferDiagnostic.self,
        from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.failures.first?.failure?.code == 7001)
    #expect(restored.failures.first?.messageID == message.messageID)
}

@Test func controlDiagnosticDistinguishesDeadlineSdkFailureAndRecoveryForTheSameMessage() throws {
    let message = ControlMessage.deleteApplied(DeleteApplied(deletionID: UUID(), deviceID: UUID()))
    let generation = UUID(), failure = TransportFailure(NSError(domain: "WCErrorDomain", code: 7012))
    let observation = ControlTransferDiagnostic.Observation(observedAt: Date(), activated: true, reachable: false)
    var diagnostic = ControlTransferDiagnostic()
    diagnostic.append(message: message, generation: generation, route: .interactive, outcome: .localDeadline,
        observation: observation, failure: failure)
    diagnostic.append(message: message, generation: generation, route: .interactive, outcome: .lateSDKError,
        observation: observation, failure: failure)
    diagnostic.append(message: message, generation: generation, route: .background, outcome: .sdkCompleted,
        observation: .init(observedAt: observation.observedAt.addingTimeInterval(1), activated: true, reachable: true))
    diagnostic.append(message: message, generation: generation, route: .interactive, outcome: .lateInboxPreserved,
        observation: .init(observedAt: observation.observedAt.addingTimeInterval(2), activated: true, reachable: true))
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(ControlTransferDiagnostic.self, from: encoder.encode(diagnostic))
    #expect(restored.entries.map(\.outcome) == [.localDeadline, .lateSDKError, .sdkCompleted, .lateInboxPreserved])
    #expect(restored.entries.map(\.route) == [.interactive, .interactive, .background, .interactive])
    #expect(restored.entries.map(\.failure?.code) == [7012, 7012, nil, nil])
    #expect(restored.entries.allSatisfy { $0.messageID == message.messageID && $0.generation == generation })
    #expect(restored.entries.first?.observation.reachable == false)
    #expect(restored.entries.last?.observation.reachable == true)
}

@Test func localControlDeadlineRetainsItsOriginWhenAnSdkErrorArrivesLater() async {
    let gate = LinkReplyGate<ControlTransferReply>()
    do {
        let _: ControlTransferReply = try await withCheckedThrowingContinuation { continuation in
            #expect(gate.install(continuation))
            gate.startDeadline(after: .milliseconds(1), failure: ControlTransferReplyFailure.localDeadline)
        }
        Issue.record("Expected the app's deadline to finish the pending request.")
    } catch ControlTransferReplyFailure.localDeadline {
        let failure = TransportFailure(NSError(domain: "WCErrorDomain", code: 7012))
        let observation = ControlTransferDiagnostic.Observation(observedAt: Date(), activated: true, reachable: false)
        #expect(!gate.finish(.failure(ControlTransferReplyFailure.sdk(failure, observation))))
    } catch { Issue.record("The deadline lost its typed origin: \(error)") }
}
