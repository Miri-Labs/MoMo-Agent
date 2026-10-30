import Foundation
import Testing
import MoMoContracts
import MoMoLink

private enum LegacyEpochControl: Decodable {
    case epochEnded(CaptureEpochEnded)
}

@Test func uncertainEpochUsesAnExplicitWireCaseAndCannotBecomeALegacyExactEnd() throws {
    let interruption = try CaptureEpochInterrupted(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
        sealedThroughFrame: 16_000, lastObservedFrame: 20_000, reason: .failed)
    let message = ControlMessage.epochInterrupted(interruption)
    #expect(try LinkWireFormat.controlMessage(LinkWireFormat.controlMetadata(message)) == message)
    let data = try WireJSON.encode(message)
    #expect(throws: DecodingError.self) { try WireJSON.decode(LegacyEpochControl.self, from: data) }
    #expect(throws: ContractError.invalidField("epoch_interruption")) {
        try CaptureEpochInterrupted(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
            sealedThroughFrame: 16_000, lastObservedFrame: 15_999, reason: .failed)
    }
    #expect(throws: ContractError.invalidField("epoch_interruption")) {
        try CaptureEpochInterrupted(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
            sealedThroughFrame: 0, lastObservedFrame: 0, reason: .stopped)
    }
}
