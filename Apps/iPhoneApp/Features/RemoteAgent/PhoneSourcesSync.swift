import Foundation
import Observation
import MoMoAgentClient

@MainActor protocol PhoneSourcesReading: AnyObject {
    var onChange: (() -> Void)? { get set }
    func authorization(_ kind: PhoneSourceKind) -> String
    func authorize(_ kind: PhoneSourceKind) async throws
    func setVisitsEnabled(_ enabled: Bool) throws
    func requestBackgroundVisits()
    func read(_ kind: PhoneSourceKind, from: Date, to: Date) async throws -> [PhoneSourceSnapshot.Record]
}

@MainActor @Observable
final class PhoneSourcesSync {
    struct Preference: Codable {
        var enabled = false
        var revision: Int64 = 0
        var pending: PhoneSourceSnapshot?
        var lastSynced: Date?
        var count = 0
        var availability = "disabled"
    }
    private struct State: Codable { let workspaceID: UUID; var sources: [String: Preference] = [:] }
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private let reader: any PhoneSourcesReading
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored var onAuthenticationRequired: ((Error) -> Void)?
    private var state: State
    private(set) var busy: Set<PhoneSourceKind> = []
    private(set) var failures: [PhoneSourceKind: String] = [:]

    init(directory: URL, deviceID: UUID, connection: AgentConnection, key: String,
         transport: (any AgentTransport)?, reader: any PhoneSourcesReading) throws {
        guard let endpoint = connection.dataURL else { throw AgentClientError.invalidEndpoint }
        file = directory.appendingPathComponent("phone-sources.json"); self.deviceID = deviceID; self.reader = reader
        client = try AgentClient(baseURL: endpoint, credential: key, assistantID: connection.assistantID, transport: transport)
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.workspaceID == connection.workspaceID else { throw AgentClientError.invalidInput }
        } else { state = State(workspaceID: connection.workspaceID) }
        try reader.setVisitsEnabled(preference(.visits).enabled)
        reader.onChange = { [weak self] in
            guard let self, active else { return }
            Task { await self.refreshAll() }
        }
    }
    func preference(_ kind: PhoneSourceKind) -> Preference { state.sources[kind.rawValue] ?? Preference() }
    func authorization(_ kind: PhoneSourceKind) -> String { reader.authorization(kind) }
    func requestBackgroundVisits() { reader.requestBackgroundVisits() }
    func foreground() {
        active = true
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
    func background() { active = false; polling?.cancel(); polling = nil }
    func refreshAll() async {
        for kind in PhoneSourceKind.allCases {
            guard !Task.isCancelled else { return }
            await refresh(kind)
        }
    }
    func enable(_ kind: PhoneSourceKind) async {
        guard !busy.contains(kind) else { return }
        busy.insert(kind)
        do {
            try await reader.authorize(kind) // Only an explicit settings action may prompt.
            var next = preference(kind); next.enabled = true
            try commit(next, kind)
            if kind == .visits { try reader.setVisitsEnabled(true) }
            failures[kind] = nil
        } catch { failures[kind] = String(localized: "授权未完成，可在系统设置中检查权限。") }
        busy.remove(kind)
        if preference(kind).enabled { await refresh(kind) }
    }
    func disable(_ kind: PhoneSourceKind) async {
        guard !busy.contains(kind) else { return }
        busy.insert(kind); defer { busy.remove(kind) }
        do {
            var next = preference(kind); next.enabled = false; next.revision += 1; next.count = 0
            next.availability = "disabled"; next.pending = snapshot(kind, next.revision, "disabled")
            try commit(next, kind) // Durable revocation replaces an unsent enabled snapshot.
            if kind == .visits { try reader.setVisitsEnabled(false) }
            try await deliver(kind)
            failures[kind] = nil
        } catch { failures[kind] = preference(kind).enabled ? String(localized: "设置未保存，请重试。") : String(localized: "已停止采集，连接 Mac 后移除副本。") }
    }
    func refresh(_ kind: PhoneSourceKind) async {
        let saved = preference(kind)
        guard !busy.contains(kind), saved.enabled || saved.pending != nil else { return }
        busy.insert(kind); defer { busy.remove(kind) }
        do {
            try Task.checkCancellation()
            let access = reader.authorization(kind)
            // Never replay personal data after system permission has been withdrawn.
            if saved.enabled && !["enabled", "foreground_only"].contains(access) {
                var next = saved; next.revision += 1; next.pending = snapshot(kind, next.revision, access)
                try commit(next, kind)
            }
            try await deliver(kind)
            guard preference(kind).enabled else { failures[kind] = nil; return }
            let now = Date(), start = now.addingTimeInterval(kind == .calendar ? -86400 : -7 * 86400)
            let end = kind == .calendar ? now.addingTimeInterval(7 * 86400) : now
            var status = access, records: [PhoneSourceSnapshot.Record] = []
            if ["enabled", "foreground_only"].contains(access) {
                do { records = try await reader.read(kind, from: start, to: end) }
                catch is CancellationError { throw CancellationError() }
                catch { status = "temporarily_unavailable" }
            }
            try Task.checkCancellation()
            var next = preference(kind); next.revision += 1
            next.pending = .init(device: deviceID, kind: kind, revision: next.revision, state: status,
                                 observedAt: now, windowStart: start, windowEnd: end, records: records)
            try commit(next, kind)
            try await deliver(kind)
            failures[kind] = ["enabled", "foreground_only"].contains(status) ? nil : String(localized: "暂时无法读取，请检查系统授权后重试。")
        } catch is CancellationError { }
        catch {
            if case AgentClientError.http(401, _, _, _) = error { background(); onAuthenticationRequired?(error) }
            failures[kind] = preference(kind).enabled ? String(localized: "尚未同步到 Mac，连接后重试。") : String(localized: "连接 Mac 后移除副本。")
        }
    }
    private func snapshot(_ kind: PhoneSourceKind, _ revision: Int64, _ state: String) -> PhoneSourceSnapshot {
        let now = Date()
        return .init(device: deviceID, kind: kind, revision: revision, state: state, observedAt: now,
                     windowStart: now, windowEnd: now, records: [])
    }
    private func deliver(_ kind: PhoneSourceKind) async throws {
        guard let pending = preference(kind).pending else { return }
        try await client.syncPhoneSource(pending)
        var next = preference(kind); next.pending = nil; next.lastSynced = Date()
        next.count = pending.records.count; next.availability = pending.state
        try commit(next, kind)
    }
    private func commit(_ value: Preference, _ kind: PhoneSourceKind) throws {
        var next = state; next.sources[kind.rawValue] = value
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = next
    }
}
