import Foundation
import Observation
import MoMoAgentClient

@MainActor @Observable
final class PhoneHealthSync {
    private struct State: Codable {
        let workspaceID: UUID
        var enabled = false
        var revision: Int64 = 0
        var pending: HealthSnapshot?
        var lastSynced: Date?
        var hasReadableData = false
    }
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private let reader: any PhoneHealthReading
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored var onAuthenticationRequired: ((Error) -> Void)?
    private var state: State
    private(set) var isSyncing = false
    private(set) var failure: String?
    var enabled: Bool { state.enabled }
    var lastSynced: Date? { state.lastSynced }
    var deletionPending: Bool { state.pending?.state == "disabled" }
    var hasReadableData: Bool { state.hasReadableData }
    var available: Bool { reader.available }

    init(directory: URL, deviceID: UUID, connection: AgentConnection, key: String, transport: (any AgentTransport)?, reader: any PhoneHealthReading = PhoneHealthReader()) throws {
        guard let endpoint = connection.dataURL else { throw AgentClientError.invalidEndpoint }
        file = directory.appendingPathComponent("health.json"); self.deviceID = deviceID; self.reader = reader
        client = try AgentClient(baseURL: endpoint, credential: key, assistantID: connection.assistantID, transport: transport)
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.workspaceID == connection.workspaceID else { throw AgentClientError.invalidInput }
            try? commit(state)
        } else { state = State(workspaceID: connection.workspaceID) }
    }

    func foreground() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
    func background() { polling?.cancel(); polling = nil }

    func enable() async {
        guard !isSyncing, available else { return }
        isSyncing = true
        do {
            try await reader.authorize()
            var next = state; next.enabled = true; try commit(next)
            failure = nil
        } catch { failure = String(localized: "健康授权未完成，请重试。") }
        isSyncing = false
        if enabled { await refresh() }
    }

    func disable() async {
        guard !isSyncing else { return }
        isSyncing = true
        do {
            var next = state; next.enabled = false; next.revision += 1; next.hasReadableData = false
            next.pending = snapshot(revision: next.revision, state: "disabled", observations: [])
            try commit(next)
            try await deliverPending()
            failure = nil
        } catch { failure = enabled ? String(localized: "无法保存设置，尚未停用，请重试。") : String(localized: "已停止采集，连接 Mac 后将移除健康副本。") }
        isSyncing = false
    }

    func refresh() async {
        guard !isSyncing, state.enabled || state.pending != nil else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try Task.checkCancellation()
            try await deliverPending() // Lost ACK retries the exact same version before reading newer data.
            if state.enabled {
                let now = Date(), calendar = Calendar.current
                let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
                let observations: [HealthSnapshot.Observation]
                var status = "enabled"
                do { observations = try await reader.read(now: now, start: start, calendar: calendar) }
                catch is CancellationError { throw CancellationError() }
                catch { observations = []; status = "temporarily_unavailable" }
                try Task.checkCancellation()
                var next = state; next.revision += 1
                next.pending = .init(device: deviceID, revision: next.revision, state: status, observedAt: now,
                                     windowStart: start, timezone: calendar.timeZone.identifier, observations: observations)
                try commit(next)
                try await deliverPending()
                failure = status == "temporarily_unavailable" ? String(localized: "暂时无法读取健康数据，请解锁手机后重试。") : nil
            } else { failure = nil }
        } catch is CancellationError { }
        catch {
            if case AgentClientError.http(401, _, _, _) = error { background(); onAuthenticationRequired?(error) }
            failure = deletionPending ? String(localized: "连接 Mac 后将移除健康副本。") : String(localized: "尚未同步到 Mac，连接后自动重试。")
        }
    }

    private func snapshot(revision: Int64, state: String, observations: [HealthSnapshot.Observation]) -> HealthSnapshot {
        let now = Date()
        return .init(device: deviceID, revision: revision, state: state, observedAt: now, windowStart: now,
                     timezone: TimeZone.current.identifier, observations: observations)
    }
    private func deliverPending() async throws {
        guard let pending = state.pending else { return }
        try await client.syncHealth(pending)
        var next = state; next.pending = nil; next.lastSynced = Date()
        next.hasReadableData = !pending.observations.isEmpty
        try commit(next)
    }
    private func commit(_ next: State) throws {
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = next
    }
}
