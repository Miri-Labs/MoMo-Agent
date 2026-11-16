import AVFAudio
import Foundation
import Observation
import UIKit
import MoMoAgentClient
import MoMoArchive
import MoMoContracts

@MainActor protocol PhoneSourcesReading: AnyObject {
    var onChange: (() -> Void)? { get set }
    func canPromptAuthorization(_ kind: PhoneSourceKind) -> Bool
    func authorization(_ kind: PhoneSourceKind) -> String
    func authorize(_ kind: PhoneSourceKind) async throws
    func setVisitsEnabled(_ enabled: Bool) throws
    func requestBackgroundVisits()
    func read(_ kind: PhoneSourceKind, from: Date, to: Date) async throws -> [PhoneSourceSnapshot.Record]
}

extension PhoneSourcesReading {
    func canPromptAuthorization(_ kind: PhoneSourceKind) -> Bool { false }
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
    @ObservationIgnored private var pendingRefresh: Set<PhoneSourceKind> = []

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
    func canPromptAuthorization(_ kind: PhoneSourceKind) -> Bool { reader.canPromptAuthorization(kind) }
    func authorization(_ kind: PhoneSourceKind) -> String { reader.authorization(kind) }
    func requestBackgroundVisits() { reader.requestBackgroundVisits() }
    func requestPermission(_ kind: PhoneSourceKind) async {
        guard !busy.contains(kind) else { return }
        busy.insert(kind)
        do {
            try await reader.authorize(kind)
            if kind == .visits, preference(kind).enabled { try reader.setVisitsEnabled(true) }
            failures[kind] = nil
        } catch {
            failures[kind] = String(localized: "授权未完成，可在系统设置中检查权限。")
        }
        busy.remove(kind)
        if preference(kind).enabled { await refresh(kind) }
    }
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
    func refreshOpportunistically(minimumInterval: TimeInterval = 15 * 60) async {
        let now = Date()
        for kind in PhoneSourceKind.allCases {
            guard !Task.isCancelled else { return }
            let saved = preference(kind)
            guard saved.pending != nil || (saved.enabled && (saved.lastSynced == nil || now.timeIntervalSince(saved.lastSynced!) >= minimumInterval)) else {
                continue
            }
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
        guard saved.enabled || saved.pending != nil else { return }
        if busy.contains(kind) {
            pendingRefresh.insert(kind)
            return
        }
        busy.insert(kind)
        defer { busy.remove(kind) }
        repeat {
            pendingRefresh.remove(kind)
            let currentSaved = preference(kind)
            guard currentSaved.enabled || currentSaved.pending != nil else { break }
            do {
                try Task.checkCancellation()
                let access = reader.authorization(kind)
                // Never replay personal data after system permission has been withdrawn.
                if currentSaved.enabled && !["enabled", "foreground_only"].contains(access) {
                    var next = currentSaved; next.revision += 1; next.pending = snapshot(kind, next.revision, access)
                    try commit(next, kind)
                }
                try await deliver(kind)
                guard preference(kind).enabled else { failures[kind] = nil; continue }
                let now = Date()
                let start = now.addingTimeInterval((kind == .calendar || kind == .motion) ? -86400 : -7 * 86400)
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
                if ["enabled", "foreground_only"].contains(status) {
                    failures[kind] = nil
                } else if reader.canPromptAuthorization(kind) {
                    failures[kind] = kind == .visits
                        ? String(localized: "尚未完成系统定位授权（例如上次选了「允许一次」已过期），请点上方「请求定位权限」。")
                        : String(localized: "尚未授予系统权限，请点上方「请求系统权限」。")
                } else {
                    failures[kind] = String(localized: "暂时无法读取，请检查系统授权后重试。")
                }
            } catch is CancellationError {
                pendingRefresh.remove(kind)
                return
            } catch {
                if case AgentClientError.http(401, _, _, _) = error { background(); onAuthenticationRequired?(error); return }
                failures[kind] = preference(kind).enabled ? String(localized: "尚未同步到 Mac，连接后重试。") : String(localized: "连接 Mac 后移除副本。")
                return
            }
        } while pendingRefresh.contains(kind) && !Task.isCancelled
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

@MainActor @Observable
final class PhoneDeviceTelemetrySync {
    private struct State: Codable {
        let workspaceID: UUID
        var enabled = true
        var revision: Int64 = 0
        var pending: DeviceTelemetrySnapshot?
        var lastSynced: Date?
        var lastPhoneBatteryState: String?
        var lastWatchBatteryState: String?
    }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let deviceID: UUID
    @ObservationIgnored private let client: AgentClient
    @ObservationIgnored private var expectedLibraryID: UUID?
    @ObservationIgnored private var latestWatchStatus: WatchStatusObservation?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var active = false
    @ObservationIgnored nonisolated(unsafe) private var notificationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored var onAuthenticationRequired: ((Error) -> Void)?

    private var state: State
    private(set) var isSyncing = false
    private(set) var failure: String?

    var enabled: Bool { state.enabled }
    var lastSynced: Date? { state.lastSynced }
    var deletionPending: Bool { state.pending?.state == "disabled" }

    init(
        directory: URL,
        deviceID: UUID,
        connection: AgentConnection,
        key: String,
        transport: (any AgentTransport)?,
        expectedLibraryID: UUID? = nil,
        initialWatchStatus: WatchStatusObservation? = nil
    ) throws {
        guard let endpoint = connection.dataURL else { throw AgentClientError.invalidEndpoint }
        self.directory = directory
        self.file = directory.appendingPathComponent("device-telemetry.json")
        self.deviceID = deviceID
        self.expectedLibraryID = expectedLibraryID
        self.latestWatchStatus = initialWatchStatus
        self.client = try AgentClient(baseURL: endpoint, credential: key, assistantID: connection.assistantID, transport: transport)
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard state.workspaceID == connection.workspaceID else { throw AgentClientError.invalidInput }
        } else {
            let initial = State(workspaceID: connection.workspaceID, enabled: true)
            state = initial
            try? commit(initial)
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let names: [Notification.Name] = [
            UIDevice.batteryStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
            AVAudioSession.routeChangeNotification
        ]
        notificationTasks = names.map { name in
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let self, self.active, self.state.enabled else { continue }
                    await self.refresh()
                }
            }
        }
    }

    deinit {
        for task in notificationTasks { task.cancel() }
    }

    func updateWatchStatus(_ observation: WatchStatusObservation?, expectedLibraryID: UUID) {
        let previousWatchBatteryState = Self.watchTelemetry(from: latestWatchStatus, expectedLibraryID: self.expectedLibraryID)?.batteryState
        self.expectedLibraryID = expectedLibraryID
        self.latestWatchStatus = observation
        let nextWatchBatteryState = Self.watchTelemetry(from: observation, expectedLibraryID: expectedLibraryID)?.batteryState
        if active, state.enabled, previousWatchBatteryState != nextWatchBatteryState {
            Task { await refresh() }
        }
    }

    func shouldRefreshOpportunistically(minimumInterval: TimeInterval = 5 * 60) -> Bool {
        if state.pending != nil { return true }
        guard state.enabled else { return false }
        if Self.currentPhoneBatteryState() != state.lastPhoneBatteryState { return true }
        if let watchState = Self.watchTelemetry(from: latestWatchStatus, expectedLibraryID: expectedLibraryID)?.batteryState,
           watchState != state.lastWatchBatteryState {
            return true
        }
        guard let lastSynced = state.lastSynced else { return true }
        return Date().timeIntervalSince(lastSynced) >= minimumInterval
    }

    func foreground() {
        active = true
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    func background() {
        active = false
        polling?.cancel()
        polling = nil
    }

    func enable() async {
        guard !isSyncing else { return }
        do {
            var next = state
            next.enabled = true
            try commit(next)
            failure = nil
        } catch {
            failure = String(localized: "设置未保存，请重试。")
            return
        }
        await refresh()
    }

    func disable() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var next = state
            next.enabled = false
            next.revision += 1
            next.pending = DeviceTelemetrySnapshot(
                device: deviceID,
                revision: next.revision,
                state: "disabled",
                observedAt: Date(),
                timezone: TimeZone.current.identifier,
                phone: nil,
                watch: nil
            )
            try commit(next)
            try await deliverPending()
            failure = nil
        } catch {
            failure = enabled
                ? String(localized: "设置未保存，请重试。")
                : String(localized: "已停止采集，连接 Mac 后移除设备状态副本。")
        }
    }

    func refresh() async {
        guard state.enabled || state.pending != nil else { return }
        if isSyncing {
            pendingRefresh = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            pendingRefresh = false
            guard state.enabled || state.pending != nil else { break }
            do {
                try Task.checkCancellation()
                try await deliverPending()
                if state.enabled {
                    let now = Date()
                    let phone = Self.readPhoneTelemetry(near: directory)
                    let watch = Self.watchTelemetry(from: latestWatchStatus, expectedLibraryID: expectedLibraryID)
                    var next = state
                    next.revision += 1
                    next.pending = DeviceTelemetrySnapshot(
                        device: deviceID,
                        revision: next.revision,
                        state: "enabled",
                        observedAt: now,
                        timezone: TimeZone.current.identifier,
                        phone: phone,
                        watch: watch
                    )
                    try commit(next)
                    try await deliverPending()
                }
                failure = nil
            } catch is CancellationError {
                pendingRefresh = false
                return
            } catch {
                if case AgentClientError.http(401, _, _, _) = error {
                    background()
                    onAuthenticationRequired?(error)
                    return
                }
                failure = deletionPending
                    ? String(localized: "连接 Mac 后移除设备状态副本。")
                    : String(localized: "尚未同步到 Mac，连接后自动重试。")
                return
            }
        } while pendingRefresh && !Task.isCancelled
    }

    private func deliverPending() async throws {
        guard let pending = state.pending else { return }
        try await client.syncDeviceTelemetry(pending)
        var next = state
        next.pending = nil
        next.lastSynced = Date()
        next.lastPhoneBatteryState = pending.phone?.batteryState
        next.lastWatchBatteryState = pending.watch?.batteryState
        try commit(next)
    }

    private func commit(_ next: State) throws {
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = next
    }

    private static func currentPhoneBatteryState() -> String {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        switch device.batteryState {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private static func readPhoneTelemetry(near directory: URL) -> DeviceTelemetrySnapshot.PhoneTelemetry {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let rawBattery = device.batteryLevel
        let batteryLevel: Double? = rawBattery >= 0 ? min(1.0, Double(rawBattery)) : nil
        let batteryState = currentPhoneBatteryState()
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermalState = min(3, max(0, ProcessInfo.processInfo.thermalState.rawValue))
        let freeStorageBytes: Int64? = {
            let probe = FileManager.default.fileExists(atPath: directory.path) ? directory : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
                if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
                    return Int64(important)
                }
                if let available = values.volumeAvailableCapacity, available >= 0 {
                    return Int64(available)
                }
            }
            return nil
        }()
        let audioRoute: DeviceTelemetrySnapshot.AudioRoute? = {
            guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
            return .init(portType: output.portType.rawValue, portName: output.portName)
        }()
        return DeviceTelemetrySnapshot.PhoneTelemetry(
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            lowPowerMode: lowPowerMode,
            thermalState: thermalState,
            freeStorageBytes: freeStorageBytes,
            audioRoute: audioRoute
        )
    }

    private static func watchTelemetry(
        from observation: WatchStatusObservation?,
        expectedLibraryID: UUID?
    ) -> DeviceTelemetrySnapshot.WatchTelemetry? {
        guard let observation,
              let expectedLibraryID,
              case .watch(let report) = observation.snapshot.payload,
              report.receiverLibraryInstanceID == expectedLibraryID else {
            return nil
        }
        return DeviceTelemetrySnapshot.WatchTelemetry(
            deviceId: observation.snapshot.sourceDeviceID.uuidString.lowercased(),
            sampledAt: observation.snapshot.sampledAt.timeIntervalSince1970,
            activity: report.activity.rawValue,
            pendingChunkCount: report.pendingChunkCount,
            pendingBytes: report.pendingBytes,
            batteryLevel: report.batteryLevel,
            batteryState: report.batteryState ?? "unknown",
            lowPowerMode: report.lowPowerMode ?? false,
            thermalState: report.thermalState ?? 0,
            freeStorageBytes: report.freeStorageBytes
        )
    }
}
