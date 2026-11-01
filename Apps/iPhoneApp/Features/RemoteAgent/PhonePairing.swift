import Foundation
import Observation
import MoMoAgentClient

@MainActor @Observable
final class PhonePairing {
    struct Pending: Codable {
        let invitation: PairingInvitation
        let credential: String
        var requestID: String?
    }
    private(set) var pending: Pending?
    private(set) var receipt: PairingReceipt?
    var failure: String?
    private(set) var completionGeneration = 0
    @ObservationIgnored private let file: URL

    init(directory: URL) throws {
        file = directory.appendingPathComponent("pending-pairing.json")
        if FileManager.default.fileExists(atPath: file.path) {
            pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: file))
        }
    }

    func scan(_ text: String) {
        do {
            let invitation = try PairingInvitation.parse(text)
            if pending?.invitation.invitationID != invitation.invitationID {
                let previous = pending.flatMap { value in
                    value.invitation.instanceID == invitation.instanceID && value.invitation.endpoint == invitation.endpoint &&
                    value.invitation.network == invitation.network && value.invitation.relayCode == invitation.relayCode ? value.credential : nil
                }
                let client = PairingClient(invitation: invitation, credential: previous)
                let value = Pending(invitation: invitation, credential: client.credential)
                try save(value); pending = value; receipt = nil
            }
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    func resume(agent: PhoneRemoteAgent, name: String) async {
        guard var value = pending else { return }
        failure = nil
        do {
            let transport: (any AgentTransport)?
            if value.invitation.network == "relay", let code = value.invitation.relayCode {
                transport = try RelayTransport(endpoint: value.invitation.endpoint, code: code)
            } else {
                transport = value.invitation.network == "tailscale" ? EmbeddedTailnetTransport(network: agent.tailnet, endpoint: value.invitation.endpoint) : nil
            }
            if value.requestID == nil, let credential = try agent.pairingCredential(for: value.invitation) {
                value = Pending(invitation: value.invitation, credential: credential)
                try save(value); pending = value
            }
            let client = PairingClient(invitation: value.invitation, credential: value.credential, transport: transport)
            if value.requestID == nil {
                let created = try await retryTransient(tailscale: value.invitation.network == "tailscale") {
                    try await client.request(name: name)
                }
                try Task.checkCancellation()
                value.requestID = created.id; try save(value); pending = value
                receipt = created
            }
            while !Task.isCancelled, pending?.invitation.invitationID == value.invitation.invitationID {
                let current = try await retryTransient(tailscale: value.invitation.network == "tailscale") {
                    try await client.status(id: value.requestID!)
                }
                try Task.checkCancellation()
                receipt = current
                switch current.state {
                case "approved":
                    guard let connection = current.connection else { throw PairingError.identityChanged }
                    let configuration = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
                    await agent.connect(configuration: configuration, credential: value.credential)
                    if let failure = agent.failure { self.failure = failure; return }
                    try clear(); completionGeneration += 1; return
                case "pending":
                    try await Task.sleep(for: .seconds(2))
                case "expired": throw PairingError.invalidCode
                case "rejected", "revoked":
                    failure = String(localized: "Mac 未允许这次连接，请重新扫码。"); return
                default: throw PairingError.unavailable
                }
            }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, !AgentTransportFailure.isCancelled(error) {
                failure = AgentTransportFailure.isTransient(error) ? String(localized: "暂时无法连接 Mac，请重试，无需重新扫码。") : error.localizedDescription
            }
        }
    }

    private func retryTransient<T>(tailscale: Bool, operation: () async throws -> T) async throws -> T {
        let maxAttempts = tailscale ? 4 : 1
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PairingError where error != .unavailable {
                throw error
            } catch {
                if attempt == maxAttempts { throw error }
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw PairingError.unavailable
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        pending = nil; receipt = nil; failure = nil
    }

    private func save(_ pending: Pending) throws {
        // Keep the phone-created secret across app termination and lost approval receipts.
        try JSONEncoder().encode(pending).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
