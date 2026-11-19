import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Observation
import MoMoAgentClient
import MoMoContracts
import Darwin

struct AccessStatus: Decodable, Equatable, Sendable {
    struct Tunnel: Decodable, Equatable, Sendable {
        let state: String; let endpoint: String?; let mode: String; let provider: String?; let error: String?
        let setupCommand: String?
        let configuredEndpoint: String?
        enum CodingKeys: String, CodingKey { case state, endpoint, mode, provider, error; case setupCommand = "setup_command"; case configuredEndpoint = "configured_endpoint" }
    }
    struct Device: Decodable, Identifiable, Equatable, Sendable { let id: String; let name: String; let code: String; let state: String; let expires: Double; let lastSeen: Double?; let endpoint: String?
        enum CodingKeys: String, CodingKey { case id, name, code, state, expires, endpoint; case lastSeen = "last_seen" }
    }
    struct Invitation: Decodable, Equatable, Sendable { let id: String; let endpoint: String; let expires: Double; let payload: String }
    let agentOnline: Bool
    let tunnel: Tunnel
    let devices: [Device]
    let invitation: Invitation?
    let pairedDeviceID: String?
    enum CodingKeys: String, CodingKey { case agentOnline = "agent_online"; case pairedDeviceID = "paired_device_id"; case tunnel, devices, invitation }
}

struct DesktopProactiveSnapshot: Sendable, Equatable {
    let dshReady: Bool
    let activeTickets: Int
    let totalDecisions: Int
    let latestSummary: String?
}

@MainActor @Observable
final class DesktopModel {
    enum SetupStep: String { case welcome, prepare, model, permissions, pair, ready, completed }
    var setupStep = SetupStep.welcome
    var selection = "chat"
    var managingConnection = false
    var managingModel = false
    var isPairingDevice = false
    var isPrepared: Bool { connection != nil }
    var hasBundledRuntime: Bool { FileManager.default.fileExists(atPath: repository.appendingPathComponent("runtime-manifest.json").path) }
    var runtimePython: URL {
        hasBundledRuntime ? repository.appendingPathComponent("python/bin/python3.14")
            : dataDirectory.appendingPathComponent("runtime/venv/bin/python")
    }
    var hasDesktopPermissions: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }
    var hasPairedPhone: Bool {
        guard let status else { return false }
        return status.devices.contains { $0.state == "approved" && $0.lastSeen != nil }
    }
    var pairingAccepted: Bool {
        guard let status, status.tunnel.state == "connected" else { return false }
        return status.devices.contains { $0.id == status.pairedDeviceID && $0.state == "approved" }
            || setupStep == .pair && hasPairedPhone && status.invitation == nil
    }
    var localAccessURL: String { connection?.baseURL.port.map { "http://127.0.0.1:\($0 + 2)" } ?? String(localized: "准备 Mac 后显示") }
    var ownsAgent: Bool { agentProcess?.isRunning == true }
    @ObservationIgnored var readingPosition: ChatReadingPosition?
    private(set) var isAgentOnline = false
    var status: AccessStatus?
    var busy: String?
    var preparationPhase: DesktopPreparationPhase?
    var preparationDownload: DesktopDownloadProgress?
    var failure: String?
    var desktopHost: DesktopControlHost?
    var desktopFailure: String?
    var endpoint = ""
    var modelProvider = DesktopModelProvider.codex {
        didSet {
            guard oldValue != modelProvider else { return }
            cancelModelConnection()
            modelDrafts[oldValue] = modelName
            modelName = modelDrafts[modelProvider] ?? ""
            modelAccount = nil
            modelAccountCheckedAt = nil
            lifeIllustrations.invalidateSupport()
            failure = nil
        }
    }
    var modelAccount: DesktopModelAccount?
    var loadingModelAccount = false
    @ObservationIgnored var modelAccountCheckedAt: Date?
    @ObservationIgnored var modelAccountRefreshTask: Task<Void, Never>?
    @ObservationIgnored var modelAccountRefreshID: UUID?
    var modelConnectionCancelled = false
    var modelLogin: DesktopModelLogin?
    @ObservationIgnored var modelLoginTask: Task<Void, Never>?
    @ObservationIgnored var modelProcess: Process?
    @ObservationIgnored private var modelDrafts: [DesktopModelProvider: String] = [:]
    var providerURL = ""
    var modelName = ""
    var providerKey = ""
    var dayStartHour = TranscriptReadingBoundary.defaultHour
    var proactiveSnapshot: DesktopProactiveSnapshot?
    var taskStore: RemoteTaskStore?
    var memories: [ContextMemory] = []
    var sources: [ContextSource] = []
    var vaultSnapshot: MemoryVaultSnapshot = .empty
    var transcriptSnapshot: DesktopTranscriptSnapshot = .empty
    @ObservationIgnored private var transcriptVersionCounter: UInt64 = 0
    var memoryError: String?
    var memoryReviewStatus: MemoryReviewStatus?
    var transcriptMemoryNeedsReview = 0
    var contextLoading = false
    let lifeIllustrations: LifeIllustrationStore
    @ObservationIgnored private var fetchingContext = false
    @ObservationIgnored private var contextRefreshRequested = false
    @ObservationIgnored private var contextRefreshNonSilent = false
    @ObservationIgnored private var lastContextRefreshAt = Date.distantPast
    @ObservationIgnored private var lastMemoriesWatermark: String?
    @ObservationIgnored private var lastSourcesWatermark: String?
    @ObservationIgnored private var lastSourcesDayStartHour: Int?
    @ObservationIgnored private var transcriptSnapshotDayHour: Int?
    let repository: URL
    let dataDirectory: URL
    let isLivePreviewClient: Bool
    private let liveSourceDirectory: URL?
    let tailnet: EmbeddedTailnet
    private(set) var tailnetAccessError: String?
    @ObservationIgnored private var lastEmbeddedEndpoint: String?
    @ObservationIgnored private var embeddedProbeFailures = 0
    @ObservationIgnored private var servedEmbeddedNode: (generation: UUID, port: Int32)?
    @ObservationIgnored private var embeddedHealth = EmbeddedAccessHealth()
    @ObservationIgnored private var lastStatusRefreshAt = Date.distantPast
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundActivity: NSObjectProtocol?
    @ObservationIgnored private var accessProcess: Process?
    @ObservationIgnored private var agentProcess: Process?
    @ObservationIgnored private var connection: AgentConnection?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var lastAgentLaunchAttempt = Date.distantPast
    @ObservationIgnored private var cachedBaseClient: (url: URL, key: String, assistantID: UUID, client: AgentClient)?
    @ObservationIgnored private var cachedDataClient: (url: URL, key: String, assistantID: UUID, client: AgentClient)?
    private var resumeKey: String { "agent.resume." + dataDirectory.path }
    @ObservationIgnored private let controlSession = URLSession(configuration: .ephemeral)

    init() {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("AgentRuntime")
        repository = argument("--repository").map { URL(fileURLWithPath: $0) }
            ?? bundled.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("runtime-manifest.json").path) ? $0 : nil }
            ?? URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MoMoRepositoryRoot") as? String ?? "")
        let dataFolder = Bundle.main.object(forInfoDictionaryKey: "MoMoDataFolder") as? String ?? "MoMoAgent"
        let resolvedDataDir = URL(fileURLWithPath: argument("--data-dir") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dataFolder)/Agent").path)
        let prodDataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MoMoAgent/Agent")
        let explicitPreview = args.contains("--attach-live-preview") || ProcessInfo.processInfo.environment["MOMO_UI_PREVIEW"] == "1"
        let autoBetaAttach = dataFolder != "MoMoAgent"
            && argument("--data-dir") == nil
            && !FileManager.default.fileExists(atPath: resolvedDataDir.appendingPathComponent("connection.json").path)
            && FileManager.default.fileExists(atPath: prodDataDir.appendingPathComponent("connection.json").path)
        if (explicitPreview || autoBetaAttach),
           FileManager.default.fileExists(atPath: prodDataDir.appendingPathComponent("connection.json").path) {
            isLivePreviewClient = true
            liveSourceDirectory = prodDataDir
        } else {
            isLivePreviewClient = false
            liveSourceDirectory = nil
        }
        dataDirectory = resolvedDataDir
        lifeIllustrations = LifeIllustrationStore(directory: dataDirectory.appendingPathComponent("life-illustrations-cache"))
        tailnet = EmbeddedTailnet(directory: dataDirectory.appendingPathComponent("tailscale"), device: "mac")
        if isLivePreviewClient {
            setupStep = .completed
        } else {
            setupStep = SetupStep(rawValue: UserDefaults.standard.string(forKey: "setup." + dataDirectory.path) ?? "welcome") ?? .welcome
        }
        if let initialSelection = argument("--selection") {
            selection = initialSelection
        }
        loadDayBoundaryConfiguration()
    }

    private static func sha256Hex(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isSuperAgentPreparedAndCurrent() -> Bool {
        let fm = FileManager.default
        let runner = dataDirectory.appendingPathComponent("runtime/superagent")
        let marker = runner.appendingPathComponent("prepared.json")
        let binary = runner.appendingPathComponent("node_modules/.bin/dsh")
        let installedBundle = runner.appendingPathComponent("node_modules/dsh-superagent/lib/index.js")
        guard fm.fileExists(atPath: marker.path),
              fm.fileExists(atPath: binary.path),
              fm.fileExists(atPath: installedBundle.path),
              let markerData = try? Data(contentsOf: marker),
              let record = (try? JSONSerialization.jsonObject(with: markerData)) as? [String: String],
              let recordedSource = record["source"],
              let recordedCommit = record["upstream_commit"],
              let recordedDshVersion = record["dsh_version"], !recordedDshVersion.isEmpty,
              let recordedManifestHash = record["manifest_sha256"],
              let recordedBundleHash = record["bundle_sha256"] else {
            return false
        }
        let resolvedRepo = repository.resolvingSymlinksInPath()
        let expectedSource = resolvedRepo.appendingPathComponent("Vendor/SuperAgent").path
        guard recordedSource == expectedSource else { return false }
        let upstreamFile = resolvedRepo.appendingPathComponent("Vendor/SuperAgent.UPSTREAM.json")
        let runtimePyFile = resolvedRepo.appendingPathComponent("Apps/MacApp/Runtime/superagent_runtime.py")
        guard let upstreamData = try? Data(contentsOf: upstreamFile),
              let upstream = (try? JSONSerialization.jsonObject(with: upstreamData)) as? [String: Any],
              let expectedCommit = upstream["commit"] as? String,
              recordedCommit == expectedCommit,
              let runtimePy = try? String(contentsOf: runtimePyFile, encoding: .utf8),
              runtimePy.contains("DSH_VERSION = \"\(recordedDshVersion)\"") else {
            return false
        }
        let manifestFile = resolvedRepo.appendingPathComponent("Vendor/SuperAgent/package.json")
        let bundleFile = resolvedRepo.appendingPathComponent("Vendor/SuperAgent/lib/index.js")
        guard Self.sha256Hex(of: manifestFile) == recordedManifestHash,
              Self.sha256Hex(of: bundleFile) == recordedBundleHash,
              Self.sha256Hex(of: installedBundle) == recordedBundleHash else {
            return false
        }
        return true
    }

    func load() async {
        guard timer == nil, !loading else { return }
        loading = true; defer { loading = false }
        if isLivePreviewClient {
            do {
                try loadConnection()
                await refresh()
            } catch {
                failure = error.localizedDescription
            }
        } else if FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connection.json").path) {
            do {
                try await reclaimStaleRuntimeProcesses()
                try loadConnection()
                let pythonPath = runtimePython.path
                let needsPythonPrep = !FileManager.default.isExecutableFile(atPath: pythonPath)
                let needsSuperAgentPrep = !isSuperAgentPreparedAndCurrent()
                if needsPythonPrep || needsSuperAgentPrep {
                    try await prepareRuntime()
                }
                do { try startAccess() } catch { try await prepareRuntime(); try startAccess() }
                for _ in 0..<12 {
                    await refresh()
                    if status != nil { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if UserDefaults.standard.bool(forKey: resumeKey), status?.agentOnline != true {
                    try launchAgent()
                }
            } catch { failure = error.localizedDescription }
        }
        if !isLivePreviewClient, backgroundActivity == nil {
            // Prevent macOS App Nap from throttling embedded tsnet WireGuard/DERP goroutines and
            // tunnel lease heartbeats when MoMo Agent's window is hidden or behind full-screen apps,
            // while still allowing normal idle system sleep.
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Keep MoMo Agent Tailnet peer and background runtime responsive"
            )
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.shuttingDown else { return }
                    self.embeddedProbeFailures = 0
                    self.servedEmbeddedNode = nil
                    self.embeddedHealth = EmbeddedAccessHealth()
                    self.tailnet.prepareForForeground()
                    await self.refresh()
                    await self.taskStore?.retryConnection()
                }
            }
        }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.shuttingDown else { return }
                    if Date().timeIntervalSince(self.lastStatusRefreshAt) >= 1.5 {
                        await self.refresh()
                    }
                }
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval: Duration
                if let self {
                    let healthy = self.setupStep == .completed
                        && !self.isPairingDevice
                        && self.status?.agentOnline == true
                        && (self.status?.tunnel.state == "connected" || self.status?.tunnel.state == "stopped")
                    interval = (!NSApplication.shared.isActive && healthy) ? .seconds(5) : .seconds(3)
                } else {
                    interval = .seconds(3)
                }
                do { try await Task.sleep(for: interval) } catch { break }
            }
        }
        if connection != nil {
            Task { [weak self] in
                await self?.loadContext(silent: true)
            }
        }
    }

    private static func openTaskStore(file: URL, connection: AgentConnection, client: AgentClient) throws -> RemoteTaskStore {
        do {
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        } catch {
            struct Header: Decodable { let connection: AgentConnection }
            if let raw = try? Data(contentsOf: file),
               let header = try? JSONDecoder().decode(Header.self, from: raw),
               !header.connection.hasSameIdentity(as: connection) {
                throw error
            }
            let backup = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".corrupted.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        }
    }

    private func baseClient(for connection: AgentConnection) throws -> AgentClient {
        if let cached = cachedBaseClient, cached.url == connection.baseURL, cached.key == key, cached.assistantID == connection.assistantID {
            return cached.client
        }
        let client = try AgentClient(baseURL: connection.baseURL, credential: key, assistantID: connection.assistantID)
        cachedBaseClient = (connection.baseURL, key, connection.assistantID, client)
        return client
    }

    private func dataClient(for connection: AgentConnection, url: URL) throws -> AgentClient {
        if let cached = cachedDataClient, cached.url == url, cached.key == key, cached.assistantID == connection.assistantID {
            return cached.client
        }
        let client = try AgentClient(baseURL: url, credential: key, assistantID: connection.assistantID)
        cachedDataClient = (url, key, connection.assistantID, client)
        return client
    }

    private static func unquoteYAMLScalar(_ raw: Substring) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
            return value
        }
        if let commentRange = value.range(of: " #") {
            value = String(value[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else if value.hasPrefix("#") {
            return ""
        }
        return value
    }

    private static func readModelConfiguration(from file: URL) -> [String: String]? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        if let config = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let model = config["model"] as? [String: Any] {
            var values: [String: String] = [:]
            for field in ["provider", "default", "base_url"] {
                if let string = model[field] as? String { values[field] = string }
            }
            return values
        }
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var inModelBlock = false
        var modelIndent: Int?
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if !inModelBlock {
                if indent == 0, trimmed == "model:" || trimmed.hasPrefix("model: #") {
                    inModelBlock = true
                    modelIndent = nil
                }
                continue
            }
            if indent == 0 { break }
            if let expected = modelIndent, indent < expected { break }
            if modelIndent == nil { modelIndent = indent }
            guard indent == modelIndent, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: colon)...]
            if ["provider", "default", "base_url"].contains(key) {
                values[key] = unquoteYAMLScalar(rawValue)
            }
        }
        return values.isEmpty ? nil : values
    }

    private var profileDirectory: URL {
        let base = liveSourceDirectory ?? dataDirectory
        let current = base.appendingPathComponent("profile")
        let legacy = base.appendingPathComponent("hermes")
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
    }

    private func readProfileConfiguration(from file: URL) async -> [String: Any] {
        let fallback: [String: Any] = [:]
        if let raw = try? Data(contentsOf: file),
           let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            return parsed
        }
        let python = runtimePython
        let bundled = hasBundledRuntime
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: file.path) else { return fallback }
        let loadedData = await Task.detached { () -> Data? in
            let p = Process()
            p.executableURL = python
            let isolation = bundled ? ["-I", "-B"] : []
            let script = """
            import json, sys
            from pathlib import Path
            raw = Path(sys.argv[1]).read_text(encoding="utf-8")
            data = None
            for kind in ("yaml", "ruamel"):
                try:
                    if kind == "yaml":
                        import yaml
                        data = yaml.safe_load(raw)
                    else:
                        from ruamel.yaml import YAML
                        data = YAML(typ="safe").load(raw)
                    break
                except Exception:
                    pass
            print(json.dumps(dict(data) if isinstance(data, dict) else {}))
            """
            p.arguments = isolation + ["-c", script, file.path]
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return data
        }.value
        if let loadedData,
           let dict = (try? JSONSerialization.jsonObject(with: loadedData)) as? [String: Any],
           !dict.isEmpty {
            return dict
        }
        return fallback
    }

    private func loadConnection() throws {
        let credentialDirectory = liveSourceDirectory ?? dataDirectory
        connection = try JSONDecoder().decode(AgentConnection.self, from: Data(contentsOf: credentialDirectory.appendingPathComponent("connection.json")))
        key = try String(contentsOf: credentialDirectory.appendingPathComponent("api-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if let connection, let url = connection.dataURL {
            lifeIllustrations.configure(client: try dataClient(for: connection, url: url), scope: connection.workspaceID.uuidString)
        }
        if !isLivePreviewClient {
            prepareDesktop()
        }
        loadDayBoundaryConfiguration()
        if let model = Self.readModelConfiguration(from: profileDirectory.appendingPathComponent("config.yaml")),
           let name = model["default"], !name.isEmpty {
            modelProvider = switch model["provider"] {
            case "openai-codex", "codex": .codex
            case "anthropic", "claude": .claude
            default: .api
            }
            providerURL = model["base_url"] ?? ""; modelName = name
        }
        // Restore the local journal before checking network availability.
        if taskStore == nil, let connection {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let localTaskFile = dataDirectory.appendingPathComponent("desktop-tasks.json")
            if isLivePreviewClient,
               !FileManager.default.fileExists(atPath: localTaskFile.path),
               let prodTasks = liveSourceDirectory?.appendingPathComponent("desktop-tasks.json"),
               FileManager.default.fileExists(atPath: prodTasks.path) {
                try? FileManager.default.copyItem(at: prodTasks, to: localTaskFile)
            }
            let client = try baseClient(for: connection)
            taskStore = try Self.openTaskStore(file: localTaskFile, connection: connection, client: client)
            if isLivePreviewClient || status?.agentOnline == true {
                taskStore?.foreground()
            }
        }
    }

    func prepare() async {
        guard busy == nil else { return }
        busy = hasBundledRuntime ? String(localized: "正在准备 MoMo…") : String(localized: "正在下载运行组件…"); failure = nil; preparationPhase = hasBundledRuntime ? .ready : .python; preparationDownload = nil
        defer { busy = nil; preparationPhase = nil; preparationDownload = nil }
        do {
            try await prepareRuntime()
            try loadConnection()
            try startAccess()
            await refresh()
        } catch { failure = error.localizedDescription }
    }

    private func prepareRuntime() async throws {
        let script = repository.appendingPathComponent("Apps/MacApp/Runtime/momo_agent.py").path
        if hasBundledRuntime {
            let prefix = ["-I", "-B", script]
            let port = Bundle.main.object(forInfoDictionaryKey: "MoMoLocalPort") as? String ?? "8765"
            if !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connection.json").path) {
                try await command(runtimePython.path, prefix + ["init", "--data-dir", dataDirectory.path, "--port", port])
            }
            try await command(runtimePython.path, prefix + ["prepare", "--data-dir", dataDirectory.path, "--progress"])
            return
        }
        let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let uv else { throw DesktopError.message(String(localized: "未找到 uv，请先安装运行环境。")) }
        if !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connection.json").path) {
            let port = Bundle.main.object(forInfoDictionaryKey: "MoMoLocalPort") as? String ?? "8765"
            try await command(uv, ["run", "--no-project", "--python", "3.14", script, "init", "--data-dir", dataDirectory.path, "--port", port])
        }
        try await command(uv, ["run", "--no-project", "--python", "3.14", script, "prepare", "--data-dir", dataDirectory.path, "--progress"])
    }

    func startAccess() throws {
        if accessProcess?.isRunning == true { return }
        accessProcess = try process("Apps/MacApp/Access/access_server.py", [])
    }

    func connectService() async {
        do { try await prepareRuntime(); try loadConnection(); try startAccess(); failure = nil } catch { failure = error.localizedDescription }
        await refresh()
    }

    func startAgent() async {
        guard busy == nil else { return }
        let wasRunning = agentProcess?.isRunning == true || status?.agentOnline == true
        if wasRunning, !ownsAgent {
            failure = String(localized: "当前 MoMo 进程由外部启动，请先停止后再切换。")
            return
        }
        busy = wasRunning ? String(localized: "正在切换并重启 MoMo…") : String(localized: "正在启动 MoMo…")
        failure = nil
        defer { busy = nil }
        do {
            modelConnectionCancelled = false
            if modelProvider == .api {
                guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let url = URL(string: providerURL), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.host != nil,
                      url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1") else { throw DesktopError.message(String(localized: "请先填写模型名称与 HTTPS API 地址。")) }
                guard !providerKey.contains(where: { $0.isNewline || $0 == "\"" || $0 == "'" }) else { throw DesktopError.message(String(localized: "API 密钥格式不正确。")) }
                let file = profileDirectory.appendingPathComponent("config.yaml")
                var config = await readProfileConfiguration(from: file)
                config["model"] = ["provider": "custom", "default": modelName, "base_url": providerURL, "context_length": 128000]
                try await verifyModel(url: url)
                try privateWrite(try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: file)
                if !providerKey.isEmpty {
                    let envFile = profileDirectory.appendingPathComponent(".env")
                    let previous = try String(contentsOf: envFile, encoding: .utf8)
                    let lines = previous.components(separatedBy: .newlines).filter { !$0.hasPrefix("OPENAI_API_KEY=") }
                    try privateWrite(Data((lines.joined(separator: "\n") + "\nOPENAI_API_KEY=" + providerKey + "\n").utf8), to: envFile); providerKey = ""
                }
            } else {
                applyModelAccount(try await modelCommand("verify", provider: modelProvider), updateSelection: false)
                guard !modelConnectionCancelled else { return }
            }
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("runtime/provider-notice.json"))
            taskStore?.clearProviderNotice()
            if agentProcess?.isRunning == true || status?.agentOnline == true {
                stopAgent()
                for _ in 0..<25 where agentProcess?.isRunning == true || status?.agentOnline == true {
                    try? await Task.sleep(for: .milliseconds(200))
                    await refresh()
                }
            }
            try startAccess()
            try launchAgent()
            UserDefaults.standard.set(true, forKey: resumeKey)
            await refresh()
        } catch { if !modelConnectionCancelled { failure = error.localizedDescription } }
    }

    private func verifyModel(url: URL) async throws {
        var credential = providerKey
        if credential.isEmpty {
            let env = try String(contentsOf: profileDirectory.appendingPathComponent(".env"), encoding: .utf8)
            credential = env.components(separatedBy: .newlines).first(where: { $0.hasPrefix("OPENAI_API_KEY=") }).map { String($0.dropFirst(15)) } ?? ""
        }
        guard !credential.isEmpty, !credential.contains(where: { $0.isNewline }) else { throw DesktopError.message(String(localized: "请填写模型 API 密钥。")) }
        var request = URLRequest(url: url.appendingPathComponent("chat/completions")); request.timeoutInterval = 30
        request.httpMethod = "POST"; request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model":modelName,"messages":[["role":"user","content":"Reply OK."]],"max_tokens":16])
        let (data, response) = try await controlSession.data(for: request, delegate: ControlNoRedirects.shared)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [401, 403].contains(statusCode) {
            throw DesktopError.message(String(localized: "自定义 API 密钥不可用，请检查密钥后重试。"))
        }
        if [402, 429].contains(statusCode) {
            throw DesktopError.message(String(localized: "当前 API 服务额度不足或正处于限流状态，请检查账户额度或更换服务。"))
        }
        guard statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw DesktopError.message(String(localized: "模型连接验证失败，请检查地址、模型名称和密钥。"))
        }
    }

    func stopAgent() {
        UserDefaults.standard.set(false, forKey: resumeKey)
        taskStore?.background()
        agentProcess?.terminate()
        // Keep ownership until termination. A second start must not race shutdown and the runtime lease.
    }

    private func launchAgent() throws {
        guard agentProcess?.isRunning != true else { return }
        lastAgentLaunchAttempt = Date()
        let running = try process("Apps/MacApp/Runtime/momo_agent.py", ["serve"])
        agentProcess = running
        running.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.agentProcess === process else { return }
                self.agentProcess = nil
                if !self.shuttingDown, UserDefaults.standard.bool(forKey: self.resumeKey) {
                    self.failure = String(localized: "MoMo 已停止，任务记录仍保留。请重新启动；运行详情见 desktop-momo_agent.log。")
                }
                await self.refresh()
            }
        }
    }

    private struct RecordedProcess: Codable {
        let pid: Int32
        let repository: String
    }

    private func pidFile(for script: String) -> URL {
        let name = URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent
        return dataDirectory.appendingPathComponent("runtime/desktop-\(name).pid")
    }

    private func isRuntimeProcess(pid: Int32, script: String) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        let name = URL(fileURLWithPath: script).lastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return output.contains(name) && output.contains(dataDirectory.path)
    }

    private func reclaimStaleRuntimeProcesses() async throws {
        for script in ["Apps/MacApp/Access/access_server.py", "Apps/MacApp/Runtime/momo_agent.py"] {
            let file = pidFile(for: script)
            guard let data = try? Data(contentsOf: file),
                  let recorded = try? JSONDecoder().decode(RecordedProcess.self, from: data) else { continue }
            if isRuntimeProcess(pid: recorded.pid, script: script), kill(recorded.pid, SIGTERM) == 0 {
                for _ in 0..<700 {
                    if kill(recorded.pid, 0) != 0 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            if isRuntimeProcess(pid: recorded.pid, script: script) {
                // Recheck identity before escalation; never lose the PID of a surviving owner.
                guard kill(recorded.pid, SIGKILL) == 0 else { throw POSIXError(.EBUSY) }
                for _ in 0..<40 {
                    if kill(recorded.pid, 0) != 0 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !isRuntimeProcess(pid: recorded.pid, script: script) else { throw POSIXError(.EBUSY) }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func process(_ script: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = runtimePython
        let isolation = hasBundledRuntime ? ["-I", "-B"] : []
        process.arguments = isolation + ["-X", "pycache_prefix=" + dataDirectory.appendingPathComponent("runtime/bytecode").path,
                             repository.appendingPathComponent(script).path] + arguments + ["--data-dir", dataDirectory.path]
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["PATH", "HOME", "USER", "LANG", "TMPDIR", "SHELL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
             "http_proxy", "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"].contains($0.key)
        }
        process.environment?["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
            + ":" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/pnpm").path
            + ":" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pnpm").path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.currentDirectoryURL = repository
        let log = dataDirectory.appendingPathComponent("runtime/desktop-" + URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent + ".log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: log.path),
           let size = attrs[.size] as? UInt64, size > 2_097_152 {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: log)
        try? handle.seekToEnd()
        process.standardOutput = handle; process.standardError = handle
        try process.run(); try handle.close()
        if let recorded = try? JSONEncoder().encode(RecordedProcess(pid: process.processIdentifier, repository: repository.resolvingSymlinksInPath().path)) {
            try? privateWrite(recorded, to: pidFile(for: script))
        }
        return process
    }

    private func command(_ executable: String, _ arguments: [String]) async throws {
        let directory = dataDirectory
        let update: @MainActor @Sendable (DesktopPreparationEvents.Event) -> Void = { [weak self] event in
            guard let self, self.preparationPhase != nil else { return }
            switch event {
            case .phase(let phase): self.preparationPhase = phase; self.preparationDownload = nil
            case .download(let name, let received, let total):
                var download = self.preparationDownload ?? DesktopDownloadProgress()
                download.record(name: name, received: received, total: total)
                self.preparationDownload = download
            }
        }
        try await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
            let log = directory.deletingLastPathComponent().appendingPathComponent("momo-prepare.log")
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            var master: Int32 = 0, slave: Int32 = 0
            var size = winsize(ws_row: 80, ws_col: 240, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(master) }
            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            p.standardInput = FileHandle.nullDevice; p.standardOutput = terminal; p.standardError = terminal
            p.environment = ProcessInfo.processInfo.environment
            p.environment?["TERM"] = "xterm-256color"; p.environment?["COLUMNS"] = "240"
            p.environment?["NO_COLOR"] = nil; p.environment?["RUST_LOG"] = nil
            p.environment?["UV_NO_PROGRESS"] = nil; p.environment?["JPY_SESSION_NAME"] = nil
            try p.run()
            try terminal.close()
            var events = DesktopPreparationEvents()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count == 0 || count < 0 && errno == EIO { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    p.terminate(); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let chunk = Data(buffer.prefix(count))
                try handle.write(contentsOf: chunk)
                for event in events.append(chunk) { await update(event) }
            }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DesktopError.message(String(localized: "运行环境准备失败，请重试。详情见 momo-prepare.log。")) }
        }.value
    }

    @discardableResult func control(_ path: String, body: [String: Any] = [:]) async -> Bool {
        guard busy == nil else { return false }
        busy = String(localized: "正在更新连接…"); defer { busy = nil }
        do {
            let next = try await controlRequest(path, body: body)
            status = next
            let nextOnline = next.agentOnline
            if isAgentOnline != nextOnline { isAgentOnline = nextOnline }
            failure = nil
            return true
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
            return false
        }
    }

    private static func isStatusEquivalentIgnoringMinorHeartbeat(_ lhs: AccessStatus?, _ rhs: AccessStatus?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?):
            guard a.agentOnline == b.agentOnline,
                  a.tunnel == b.tunnel,
                  a.invitation == b.invitation,
                  a.pairedDeviceID == b.pairedDeviceID,
                  a.devices.count == b.devices.count else { return false }
            for (d1, d2) in zip(a.devices, b.devices) {
                guard d1.id == d2.id,
                      d1.name == d2.name,
                      d1.code == d2.code,
                      d1.state == d2.state,
                      d1.expires == d2.expires,
                      d1.endpoint == d2.endpoint else { return false }
                switch (d1.lastSeen, d2.lastSeen) {
                case (nil, nil): continue
                case let (s1?, s2?):
                    if Int(s1 / 30) != Int(s2 / 30) { return false }
                default: return false
                }
            }
            return true
        default: return false
        }
    }

    private func updateStatus(_ next: AccessStatus?) {
        let nextOnline = next?.agentOnline == true
        if isAgentOnline != nextOnline {
            isAgentOnline = nextOnline
        }
        if !Self.isStatusEquivalentIgnoringMinorHeartbeat(status, next) {
            status = next
        }
    }

    func refresh() async {
        guard connection != nil, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        lastStatusRefreshAt = Date()
        let wasAgentOnline = status?.agentOnline == true
        do {
            updateStatus(try await controlRequest("status"))
            if !isLivePreviewClient {
                restorePairedInstallationIfNeeded()
                if !shuttingDown, busy == nil, UserDefaults.standard.bool(forKey: resumeKey),
                   status?.agentOnline != true, agentProcess?.isRunning != true,
                   Date().timeIntervalSince(lastAgentLaunchAttempt) >= 6 {
                    try? launchAgent()
                }
                if status?.agentOnline == true,
                   failure == String(localized: "MoMo 已停止，任务记录仍保留。请重新启动；运行详情见 desktop-momo_agent.log。") {
                    failure = nil
                }
                await refreshEmbeddedAccess()
                if setupStep == .pair || isPairingDevice {
                    if status?.tunnel.state == "connected", status?.invitation == nil, !pairingAccepted {
                        updateStatus(try await controlRequest("pair/invite", body: [:]))
                    }
                }
            }
            if status?.agentOnline == true, let connection {
                if taskStore == nil {
                    let client = try baseClient(for: connection)
                    taskStore = try Self.openTaskStore(file: dataDirectory.appendingPathComponent("desktop-tasks.json"), connection: connection, client: client)
                }
                taskStore?.foreground()
                if !wasAgentOnline || taskStore?.connectionState == .retrying {
                    Task { [weak self] in await self?.taskStore?.retryConnection(ifNeeded: true) }
                }
            }
            let bgInterval: TimeInterval = NSApplication.shared.isActive ? 15 : 45
            if status?.agentOnline == true, !fetchingContext, Date().timeIntervalSince(lastContextRefreshAt) >= bgInterval {
                Task { [weak self] in await self?.loadContext(silent: true) }
            }
            if status?.agentOnline == true {
                Task { [weak self] in await self?.lifeIllustrations.refresh(minimumInterval: bgInterval) }
            } else if proactiveSnapshot != nil {
                proactiveSnapshot = nil
            }
        } catch {
            updateStatus(nil)
            if !isLivePreviewClient, !shuttingDown, isPrepared, accessProcess?.isRunning != true {
                try? startAccess()
            }
        }
    }

    private func restorePairedInstallationIfNeeded() {
        guard hasPairedPhone else { return }
        let defaults = UserDefaults.standard
        // An explicit stop always wins. Older installs may have only the data directory.
        if defaults.object(forKey: resumeKey) == nil,
           let config = Self.readModelConfiguration(from: profileDirectory.appendingPathComponent("config.yaml")),
           let provider = config["provider"], !provider.isEmpty,
           let model = config["default"], !model.isEmpty {
            defaults.set(true, forKey: resumeKey)
        }
        let setupKey = "setup." + dataDirectory.path
        if defaults.object(forKey: setupKey) == nil, status?.agentOnline == true {
            advanceSetup(.completed)
        }
    }

    nonisolated private static func decodeAccessStatus(_ data: Data) throws -> AccessStatus {
        try JSONDecoder().decode(AccessStatus.self, from: data)
    }

    private func controlRequest(_ path: String, body: [String: Any]? = nil) async throws -> AccessStatus {
        guard let connection, let port = connection.baseURL.port,
              let url = URL(string: "http://127.0.0.1:\(port + 3)/" + path) else { throw DesktopError.message(String(localized: "请先准备运行环境。")) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await controlSession.data(for: request, delegate: ControlNoRedirects.shared)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if path.hasPrefix("tunnel/") {
                throw DesktopError.message(String(localized: "连接设置未完成，请检查地址和网络后重试。"))
            }
            throw DesktopError.message(String(localized: "操作未完成，请检查连接状态；配对码可能已过期。"))
        }
        return try await Task.detached(priority: .utility) {
            try Self.decodeAccessStatus(data)
        }.value
    }

    func applyNetworkProxy(_ settings: TailnetProxySettings) async throws {
        servedEmbeddedNode = nil
        embeddedHealth = EmbeddedAccessHealth()
        try await tailnet.updateProxy(settings)
        await refreshEmbeddedAccess()
    }

    private func refreshEmbeddedAccess() async {
        guard busy == nil else { return }
        guard status?.tunnel.mode == "embedded", status?.tunnel.state != "stopped" else {
            servedEmbeddedNode = nil
            embeddedHealth = EmbeddedAccessHealth()
            if tailnet.node != nil { await tailnet.close() }
            return
        }
        let knownEndpoint = lastEmbeddedEndpoint ?? status?.tunnel.endpoint ?? status?.tunnel.configuredEndpoint
        if lastEmbeddedEndpoint == nil, let knownEndpoint { lastEmbeddedEndpoint = knownEndpoint }
        var body: [String: Any] = ["state": "needs_setup", "error": String(localized: "请登录 Tailscale。")]
        var probeSession: URLSession?
        var probe: (endpoint: URL, generation: UUID)?
        do {
            try await tailnet.start()
            if tailnet.state == "Running", let host = tailnet.address, let node = tailnet.node,
               let port = connection?.baseURL.port {
                let targetPort = Int32(port + 2)
                let url = URL(string: "http://\(host):\(TailnetEndpoint.port)")!
                let currentGen = tailnet.generation
                let alreadyServing = servedEmbeddedNode?.generation == currentGen && servedEmbeddedNode?.port == targetPort
                let alreadyConnected = alreadyServing
                    && status?.tunnel.state == "connected"
                    && status?.tunnel.endpoint == url.absoluteString
                    && embeddedProbeFailures == 0
                    && tailnetAccessError == nil
                let needsInteractiveCheck = setupStep == .pair || isPairingDevice
                if !alreadyServing {
                    embeddedHealth = EmbeddedAccessHealth()
                    try await node.serveLoopbackHTTP(port: targetPort)
                    servedEmbeddedNode = (currentGen, targetPort)
                }
                if !alreadyConnected || needsInteractiveCheck || embeddedHealth.needsProbe(url) {
                    var request = URLRequest(url: url.appendingPathComponent("pair/identity")); request.timeoutInterval = 5
                    probe = (url, currentGen)
                    let response: (data: Data, status: Int, contentType: String?, retryAfter: String?)
                    do {
                        let session = try await tailnet.connectedSession()
                        probeSession = session
                        response = try await TailnetChunkStream.read(request, session: session, network: tailnet, limit: 64 * 1024)
                    } catch where AgentTransportFailure.isSocketOrLinkFailure(error) || AgentTransportFailure.isConfigurationFailure(error) {
                        if let probeSession { tailnet.failedRequest(error, session: probeSession) }
                        try await Task.sleep(for: .milliseconds(250))
                        let retrySession = try await tailnet.connectedSession()
                        probeSession = retrySession
                        response = try await TailnetChunkStream.read(request, session: retrySession, network: tailnet, limit: 64 * 1024)
                    }
                    let instanceID = try await Task.detached(priority: .utility) {
                        (try? JSONSerialization.jsonObject(with: response.data) as? [String: String])?["instance_id"]
                    }.value
                    guard tailnet.generation == currentGen, servedEmbeddedNode?.generation == currentGen else { return }
                    guard response.status == 200, let instanceID,
                          instanceID.lowercased() == connection?.instanceID.uuidString.lowercased() else { throw TailnetError.unavailable }
                    embeddedProbeFailures = 0
                    embeddedHealth.confirm(url)
                    lastEmbeddedEndpoint = url.absoluteString
                    if tailnetAccessError != nil { tailnetAccessError = nil }
                } else if !embeddedHealth.needsReport() {
                    return
                }
                body = ["state": "connected", "endpoint": url.absoluteString]
            } else {
                servedEmbeddedNode = nil
                if tailnetAccessError != nil { tailnetAccessError = nil }
                if let knownEndpoint, !["NeedsLogin", "NeedsMachineAuth"].contains(tailnet.state) {
                    body = ["state": "reconnecting", "endpoint": knownEndpoint,
                            "error": tailnet.state == "Running" ? String(localized: "正在连接…") : String(localized: "正在恢复连接…")]
                } else {
                    body["error"] = tailnet.state == "Running" ? String(localized: "正在连接…") : tailnet.message ?? String(localized: "请登录 Tailscale。")
                }
            }
        } catch let error where probe != nil && AgentTransportFailure.isConfigurationFailure(error) {
            // Retire any poisoned probe session immediately so a transient SOCKS5 bypass never sticks.
            tailnet.diagnostics.recordLink("identityProbe", "configuration-rejected", error: error)
            if let probeSession { tailnet.failedRequest(error, session: probeSession) }
            guard let probe, probe.generation == tailnet.generation,
                  servedEmbeddedNode?.generation == probe.generation else { return }
            let url = probe.endpoint
            if embeddedHealth.recentlyVerified(url) {
                body = ["state": "connected", "endpoint": url.absoluteString]
            } else if let knownEndpoint, !["NeedsLogin", "NeedsMachineAuth"].contains(tailnet.state) {
                servedEmbeddedNode = nil
                embeddedProbeFailures += 1
                if embeddedProbeFailures >= 3 {
                    embeddedProbeFailures = 0
                    await tailnet.restartForRecovery()
                } else {
                    tailnet.prepareForForeground()
                }
                if tailnetAccessError != nil { tailnetAccessError = nil }
                body = ["state": "reconnecting", "endpoint": knownEndpoint, "error": String(localized: "正在恢复连接…")]
            } else {
                tailnetAccessError = error.localizedDescription
                body = ["state": "needs_setup", "error": error.localizedDescription]
            }
        } catch {
            guard !AgentTransportFailure.isCancelled(error) else { return }
            if let probe, probe.generation != tailnet.generation { return }
            servedEmbeddedNode = nil
            embeddedHealth = EmbeddedAccessHealth()
            if let probeSession { tailnet.failedRequest(error, session: probeSession) }
            if let knownEndpoint, !["NeedsLogin", "NeedsMachineAuth"].contains(tailnet.state) {
                embeddedProbeFailures += 1
                if embeddedProbeFailures >= 3 {
                    embeddedProbeFailures = 0
                    await tailnet.restartForRecovery()
                } else {
                    tailnet.prepareForForeground()
                }
                if tailnetAccessError != nil { tailnetAccessError = nil }
                body = ["state": "reconnecting", "endpoint": knownEndpoint, "error": String(localized: "正在恢复连接…")]
            } else {
                let errText = String(localized: "连接未完成，请重试。")
                if tailnetAccessError != errText { tailnetAccessError = errText }
                body["error"] = errText
            }
        }
        do {
            updateStatus(try await controlRequest("tunnel/embedded", body: body))
            embeddedHealth.lastReport = .now
        }
        catch { if !AgentTransportFailure.isTransient(error) { failure = error.localizedDescription } }
    }

    func logoutTailnet() async {
        guard busy == nil else { return }
        busy = String(localized: "正在退出账号…"); defer { busy = nil }
        do {
            updateStatus(try await controlRequest("tunnel/stop", body: [:]))
            lastEmbeddedEndpoint = nil; embeddedProbeFailures = 0
            servedEmbeddedNode = nil; embeddedHealth = EmbeddedAccessHealth()
            try await tailnet.logout()
        } catch { failure = error.localizedDescription }
    }

    nonisolated private static func fetchAllMemories(client: AgentClient) async throws -> [ContextMemory] {
        for attempt in 0..<4 {
            var collected: [ContextMemory] = []
            var cursor: String?
            var revision: Int64?
            do {
                repeat {
                    let page = try await client.memories(after: cursor, revision: revision, limit: 200)
                    collected += page.items
                    cursor = page.nextCursor
                    revision = page.revision
                } while cursor != nil
                return collected
            } catch AgentClientError.http(409, "revision_conflict", _, _) where attempt < 3 {
                try await Task.sleep(for: .milliseconds(150))
                continue
            }
        }
        return []
    }

    nonisolated private static func fetchAllSources(client: AgentClient) async throws -> [ContextSource] {
        var recordings: [ContextSource] = []
        var cursor: String?
        repeat {
            let page = try await client.sources(after: cursor, summarize: true, limit: 200)
            recordings += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return recordings
    }

    func loadContextIfStale(maxAge: TimeInterval = 10) async {
        let hasData = !memories.isEmpty || !sources.isEmpty
        if hasData && Date().timeIntervalSince(lastContextRefreshAt) < maxAge {
            return
        }
        await loadContext(silent: hasData)
    }

    func loadContext(silent: Bool = false) async {
        if fetchingContext {
            contextRefreshRequested = true
            contextRefreshNonSilent = contextRefreshNonSilent || !silent
            return
        }
        guard let connection, let url = connection.dataURL else {
            let err = String(localized: "Mac 尚未连接。")
            if memoryError != err { memoryError = err }
            return
        }
        fetchingContext = true
        var runSilent = silent
        defer {
            fetchingContext = false
            if contextLoading { contextLoading = false }
        }
        repeat {
            contextRefreshRequested = false
            if contextRefreshNonSilent {
                runSilent = false
                contextRefreshNonSilent = false
            }
            let showLoading = !runSilent || (sources.isEmpty && memories.isEmpty)
            if showLoading && !contextLoading { contextLoading = true }
            lastContextRefreshAt = Date()
            do {
                let client = try dataClient(for: connection, url: url)
                let contextStatus = try await client.contextStatus()
                if memoryReviewStatus != contextStatus.memoryReview {
                    memoryReviewStatus = contextStatus.memoryReview
                }
                let nextNeedsReview = contextStatus.memoryNeedsReview ?? 0
                if transcriptMemoryNeedsReview != nextNeedsReview {
                    transcriptMemoryNeedsReview = nextNeedsReview
                }
                let memWatermark = contextStatus.memoriesWatermark
                let srcWatermark = contextStatus.sourcesWatermark
                let currentStartHour = dayStartHour
                let needMemories = !runSilent || memories.isEmpty || memWatermark == nil || memWatermark != lastMemoriesWatermark
                let needSources = !runSilent || sources.isEmpty || srcWatermark == nil || srcWatermark != lastSourcesWatermark || lastSourcesDayStartHour != currentStartHour

                let fetchedMemories: [ContextMemory]?
                let fetchedSources: [ContextSource]?
                if needMemories && needSources {
                    async let memoriesTask = Self.fetchAllMemories(client: client)
                    async let sourcesTask = Self.fetchAllSources(client: client)
                    let (m, s) = try await (memoriesTask, sourcesTask)
                    fetchedMemories = m
                    fetchedSources = s
                } else if needMemories {
                    fetchedMemories = try await Self.fetchAllMemories(client: client)
                    fetchedSources = nil
                } else if needSources {
                    fetchedMemories = nil
                    fetchedSources = try await Self.fetchAllSources(client: client)
                } else {
                    fetchedMemories = nil
                    fetchedSources = nil
                }

                if let collected = fetchedMemories {
                    lastMemoriesWatermark = memWatermark
                    let prevMemories = memories
                    let builtVault: MemoryVaultSnapshot? = await Task.detached(priority: .userInitiated) {
                        guard prevMemories != collected else { return nil }
                        return MemoryVaultSnapshot.build(from: collected)
                    }.value
                    if let builtVault {
                        memories = collected
                        vaultSnapshot = builtVault
                    }
                }
                if let recordings = fetchedSources {
                    lastSourcesWatermark = srcWatermark
                    lastSourcesDayStartHour = currentStartHour
                    let prevSources = sources
                    let hourChanged = transcriptSnapshotDayHour != currentStartHour
                    let candidateVer = transcriptVersionCounter &+ 1
                    let builtTranscripts: DesktopTranscriptSnapshot? = await Task.detached(priority: .userInitiated) {
                        guard hourChanged || prevSources != recordings else { return nil }
                        return DesktopTranscriptSnapshot.build(sources: recordings, dayStartHour: currentStartHour, version: candidateVer)
                    }.value
                    if let builtTranscripts {
                        transcriptVersionCounter = candidateVer
                        sources = recordings
                        transcriptSnapshot = builtTranscripts
                        transcriptSnapshotDayHour = currentStartHour
                    }
                }
                if memoryError != nil {
                    memoryError = nil
                }
            } catch {
                let isRevisionRace: Bool = {
                    if case AgentClientError.http(409, "revision_conflict", _, _) = error { return true }
                    return false
                }()
                if AgentTransportFailure.isTransient(error) || isRevisionRace {
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(1500))
                        await self?.loadContext(silent: true)
                    }
                } else if !runSilent {
                    let nextErr = error.localizedDescription
                    if memoryError != nextErr { memoryError = nextErr }
                }
            }
            runSilent = true
        } while contextRefreshRequested && !Task.isCancelled
    }

    func forgetMemory(_ memory: ContextMemory) async throws {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        do {
            try await dataClient(for: connection, url: url).forget(ForgetMemory(memory: memory))
            await loadContext()
        } catch AgentClientError.http(409, "revision_conflict", _, _) {
            await loadContext()
            throw DesktopError.message(String(localized: "该条记忆刚刚已更新，列表已刷新，请核对后再删除。"))
        }
    }

    func triggerDream() async throws {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        _ = try await dataClient(for: connection, url: url).triggerDream()
        await loadContext()
    }

    func readSource(_ source: ContextSource, offset: Int = 0, limit: Int? = nil) async throws -> SourceTextPage {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        return try await dataClient(for: connection, url: url).sourceText(source, offset: offset, limit: limit)
    }

    func readRecordingCitation(_ citation: RecordingCitation) async throws -> ResolvedRecordingCitation {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        return try await dataClient(for: connection, url: url).recordingCitation(citation)
    }

    func advanceSetup(_ step: SetupStep) {
        setupStep = step; failure = nil
        UserDefaults.standard.set(step.rawValue, forKey: "setup." + dataDirectory.path)
    }
    func continueWelcome() {
        if !isPrepared {
            advanceSetup(.prepare)
        } else if status?.agentOnline != true {
            advanceSetup(.model)
        } else {
            advanceSetup(hasDesktopPermissions ? .pair : .permissions)
        }
    }
    func prepareAndContinue() async { await prepare(); if isPrepared && failure == nil { advanceSetup(.model) } }
    func startAndContinue() async {
        await startAgent()
        guard failure == nil, !modelConnectionCancelled else { return }
        busy = String(localized: "正在等待 MoMo 就绪…"); defer { busy = nil }
        for _ in 0..<60 {
            await refresh()
            if status?.agentOnline == true { advanceSetup(hasDesktopPermissions ? .pair : .permissions); return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        failure = String(localized: "MoMo 尚未就绪，请检查模型配置后重试。")
    }
    func inviteForPairing() async -> Bool {
        if status?.tunnel.state == "connected" { return await control("pair/invite") }
        return await control("pair/invite", body: ["lan": true])
    }
    func beginPairing() async {
        if status?.invitation == nil, !pairingAccepted {
            _ = await inviteForPairing()
        }
    }
    func rememberReadingPosition(_ position: ChatReadingPosition) {
        readingPosition = position
        guard let store = taskStore, position.sessionID == store.connection.assistantID else { return }
        let visible = Set(position.visibleMessageIDs ?? [])
        if let seq = store.messages.last(where: { $0.sourceSession == nil && visible.contains($0.id) })?.seq {
            Task { await store.markVisibleMessagesRead(through: seq) }
        }
    }

    func prepareDesktop() {
        guard desktopHost == nil, !key.isEmpty, let port = connection?.baseURL.port else { return }
        do { desktopHost = try DesktopControlHost(data: dataDirectory, key: key, tailnet: tailnet, controlPort: port + 3); desktopFailure = nil }
        catch { desktopFailure = error.localizedDescription }
    }

    func shutdown() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver); self.activeObserver = nil }
        if let backgroundActivity { ProcessInfo.processInfo.endActivity(backgroundActivity); self.backgroundActivity = nil }
        Task { await tailnet.close() }
        desktopHost?.stop(); desktopHost = nil
        cancelModelConnection()
        shuttingDown = true; timer?.cancel(); taskStore?.background(); accessProcess?.terminate(); agentProcess?.terminate()
        controlSession.finishTasksAndInvalidate()
    }
    func showFiles() { NSWorkspace.shared.open(dataDirectory.appendingPathComponent("workspace")) }

    func loadDayBoundaryConfiguration() {
        let base = liveSourceDirectory ?? dataDirectory
        let file = base.appendingPathComponent("runtime/transcript-reading.json")
        let resolved: Int
        if let raw = try? Data(contentsOf: file),
           let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let hour = parsed["early_transcript_hour"] as? Int,
           TranscriptReadingBoundary.hourRange.contains(hour) {
            resolved = hour
        } else {
            resolved = TranscriptReadingBoundary.resolvedHour()
        }
        dayStartHour = resolved
    }

    private func writeDayBoundaryConfiguration(hour: Int) throws {
        let file = dataDirectory.appendingPathComponent("runtime/transcript-reading.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try JSONSerialization.data(withJSONObject: ["early_transcript_hour": hour], options: [.sortedKeys])
        try privateWrite(encoded, to: file)
    }

    func selectDayStartHour(_ hour: Int) {
        guard TranscriptReadingBoundary.hourRange.contains(hour), hour != dayStartHour else { return }
        do {
            try writeDayBoundaryConfiguration(hour: hour)
            UserDefaults.standard.set(hour, forKey: TranscriptReadingBoundary.defaultsKey)
            dayStartHour = hour
            if !sources.isEmpty {
                transcriptVersionCounter &+= 1
                let nextVer = transcriptVersionCounter
                let existingSources = sources
                Task { [weak self] in
                    let rebuilt = await Task.detached(priority: .userInitiated) {
                        DesktopTranscriptSnapshot.build(sources: existingSources, dayStartHour: hour, version: nextVer)
                    }.value
                    guard let self, self.dayStartHour == hour, self.sources == existingSources else { return }
                    self.transcriptSnapshot = rebuilt
                    self.transcriptSnapshotDayHour = hour
                }
            }
            if connection != nil { Task { await loadContext(silent: true) } }
        } catch { memoryError = String(localized: "阅读设置未保存，请重试。") }
    }

    nonisolated private static func parseProactiveSnapshot(_ data: Data) -> DesktopProactiveSnapshot? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let ready = (json["dsh_ready"] as? Bool) ?? false
        let tickets = (json["tickets"] as? [[String: Any]]) ?? []
        let decisions = (json["decisions"] as? [[String: Any]]) ?? []
        let activeCount = tickets.filter { item in
            let state = (item["state"] as? String) ?? (item["outcome"] as? String) ?? ""
            return !["ended", "completed", "merged", "dropped", "stopped", "canceled"].contains(state)
        }.count
        let latest = decisions.first.flatMap { item -> String? in
            let kind = (item["kind"] as? String) ?? ""
            if kind.isEmpty { return nil }
            if let reason = item["reason"] as? String, !reason.isEmpty {
                return "\(kind): \(reason)"
            }
            if let reasons = item["reason"] as? [[String: Any]],
               let code = reasons.first?["code"] as? String, !code.isEmpty {
                return "\(kind): \(code)"
            }
            return kind
        }
        return DesktopProactiveSnapshot(
            dshReady: ready,
            activeTickets: activeCount,
            totalDecisions: decisions.count,
            latestSummary: latest
        )
    }

    func refreshProactiveSnapshot() async {
        guard let connection, !key.isEmpty else { return }
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("momo/v1/proactive"))
        request.timeoutInterval = 5
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await controlSession.data(for: request, delegate: ControlNoRedirects.shared),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        guard let next = await Task.detached(priority: .utility, operation: {
            Self.parseProactiveSnapshot(data)
        }).value else { return }
        if proactiveSnapshot != next {
            proactiveSnapshot = next
        }
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self {
            return Bundle.main.localizedString(forKey: message, value: message, table: nil)
        }
        return nil
    }
}

private final class ControlNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ControlNoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
