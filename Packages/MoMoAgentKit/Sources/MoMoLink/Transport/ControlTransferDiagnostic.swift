import Foundation
import MoMoContracts

/// A bounded, payload-free history survives app suspension and can be copied without a live log stream.
struct ControlTransferDiagnostic: Codable, Sendable {
    static let maximumEntries = 32
    static let maximumFailures = 16
    struct Observation: Codable, Sendable, Equatable {
        let observedAt: Date
        let activated: Bool
        let reachable: Bool
    }
    enum Route: String, Codable, Sendable { case interactive, background }
    enum Outcome: String, Codable, Sendable {
        case inboxPreserved, inboxRejected, sdkCompleted, sdkError, localDeadline, localError
        case lateInboxPreserved, lateSDKError
    }
    struct Failure: Codable, Sendable, Equatable {
        let domain: String
        let code: Int
        let underlyingDomain: String?
        let underlyingCode: Int?
        init(_ failure: TransportFailure) {
            domain = failure.domain; code = failure.code
            underlyingDomain = failure.underlyingDomain; underlyingCode = failure.underlyingCode
        }
    }
    struct Entry: Codable, Sendable {
        let messageID: UUID
        let kind: String
        let generation: UUID?
        let route: Route
        let outcome: Outcome
        let observation: Observation
        let failure: Failure?
    }
    private(set) var entries: [Entry] = []
    private(set) var failures: [Entry] = []

    private enum CodingKeys: String, CodingKey { case entries, failures }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([Entry].self, forKey: .entries)
        failures = try container.decodeIfPresent([Entry].self, forKey: .failures)
            ?? Array(entries.filter { $0.failure != nil || $0.outcome == .inboxRejected }.suffix(Self.maximumFailures))
        guard entries.count <= Self.maximumEntries, failures.count <= Self.maximumFailures else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Control diagnostic exceeds its entry limit"))
        }
    }

    mutating func append(message: ControlMessage, generation: UUID?, route: Route, outcome: Outcome,
                         observation: Observation, failure: TransportFailure? = nil) {
        let entry = Entry(messageID: message.messageID, kind: Self.kind(message), generation: generation,
            route: route, outcome: outcome, observation: observation, failure: failure.map(Failure.init))
        entries.append(entry)
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
        // Receipt bursts must not erase the failure before device diagnostics can be collected.
        if failure != nil || outcome == .inboxRejected {
            failures.append(entry)
            if failures.count > Self.maximumFailures { failures.removeFirst(failures.count - Self.maximumFailures) }
        }
    }

    static func kind(_ message: ControlMessage) -> String {
        switch message {
        case .receiverIdentity: "receiverIdentity"
        case .epochEnded: "epochEnded"
        case .epochInterrupted: "epochInterrupted"
        case .captureMark: "captureMark"
        case .receipt: "receipt"
        case .receiptApplied: "receiptApplied"
        case .deleteSession: "deleteSession"
        case .deleteApplied: "deleteApplied"
        case .reconcileRequest: "reconcileRequest"
        case .reconcileResponse: "reconcileResponse"
        }
    }
}

struct ControlTransferReply: Sendable {
    let preserved: Bool
    let observation: ControlTransferDiagnostic.Observation
}

enum ControlTransferReplyFailure: Error {
    case sdk(TransportFailure, ControlTransferDiagnostic.Observation)
    case localDeadline
}
