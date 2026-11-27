import Foundation
import Observation
import Network
import TailscaleKit
import MoMoAgentClient

/// One application node. Login state persists separately from MoMo device authorization.
@MainActor @Observable
final class EmbeddedTailnet {
    private(set) var state = "stopped"
    private(set) var message: String?
    private(set) var authURL: URL?
    private(set) var address: String?
    private(set) var generation = UUID()
    private(set) var node: TailscaleNode?
    private(set) var proxySettings = TailnetProxySettings()
    private(set) var proxySettingsError: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let hostname: String
    @ObservationIgnored private let controlURL: String
    @ObservationIgnored let diagnostics: TailnetDiagnostics
    @ObservationIgnored private var startup: Task<TailscaleNode, Error>?
    @ObservationIgnored private var mappedAddresses = Set<String>()
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var up: Task<Void, Never>?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var interactiveSession: URLSession?
    @ObservationIgnored private var desktopControlSession: URLSession?
    @ObservationIgnored private var desktopMediaSession: URLSession?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var needsRestart = false
    @ObservationIgnored private var localProxyDead = false
    @ObservationIgnored private var needsProxyCheck = false
    @ObservationIgnored private var proxyCheck: Task<Void, Never>?
    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var lastRecoveryRestart: ContinuousClock.Instant?
    @ObservationIgnored private var lastLocalProxyRebuild: ContinuousClock.Instant?
    @ObservationIgnored private var needsPeerWarmup = true
    @ObservationIgnored private var lastPeerWarmupAt: ContinuousClock.Instant?
    @ObservationIgnored private var peerWarmup: Task<Void, Never>?
    @ObservationIgnored private var peerWarmupWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var signingOut = false
    @ObservationIgnored private var signedOut = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored var startupTimeout: Duration = .seconds(15)
    @ObservationIgnored var peerMapTimeout: Duration = .seconds(12)
    @ObservationIgnored var peerWarmupTimeout: Duration = .seconds(4)
    @ObservationIgnored var recoveryRestartInterval: Duration = .seconds(60)
    @ObservationIgnored var localProxyRebuildInterval: Duration = .milliseconds(500)

    private static let startupStates: Set<String> = ["starting", "Starting", "NoState", "Stopped", "stopped"]

    init(directory: URL, device: String, controlURL: String = kDefaultControlURL) {
        self.directory = directory
        self.controlURL = controlURL
        do { proxySettings = try TailnetProxySettings.read(from: directory) }
        catch { proxySettingsError = String(localized: "无法读取网络代理设置，请在设置中重新保存。") }
        diagnostics = TailnetDiagnostics(directory: directory)
        hostname = "momo-" + device + "-" + String(directory.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber }.suffix(8))
    }

    private var canRebuildForRecoveryNow: Bool {
        guard let lastRecoveryRestart else { return true }
        return lastRecoveryRestart.duration(to: .now) >= recoveryRestartInterval
    }

    private var canRebuildDeadLocalProxyNow: Bool {
        guard let lastLocalProxyRebuild else { return true }
        return lastLocalProxyRebuild.duration(to: .now) >= localProxyRebuildInterval
    }

    private func rebuildDeadLocalProxy() async throws {
        if let lastLocalProxyRebuild, lastLocalProxyRebuild.duration(to: .now) < localProxyRebuildInterval {
            let remaining = localProxyRebuildInterval - lastLocalProxyRebuild.duration(to: .now)
            if remaining > .zero { try await Task.sleep(for: remaining) }
        }
        lastLocalProxyRebuild = .now
        await close()
    }

    func start() async throws {
        guard proxySettingsError == nil else { throw TailnetError.unavailable }
        let checkedProxy = needsProxyCheck
        await checkProxyIfNeeded()
        if let closing { await closing.value }
        try Task.checkCancellation()
        guard !signingOut, !signedOut else { throw TailnetError.loginRequired }
        if localProxyDead {
            try await rebuildDeadLocalProxy()
            return try await start()
        }
        if needsRestart, (node == nil || canRebuildForRecoveryNow) {
            try await rebuildForRecovery()
            return try await start()
        }
        if let existing = node {
            let attempt = generation
            let recoveringWithinCooldown = needsRestart
            if checkedProxy || state != "Running" || recoveringWithinCooldown {
                await refreshStatus(ignoreFailedRestartGate: recoveringWithinCooldown)
                try Task.checkCancellation()
                guard attempt == generation else { throw CancellationError() }
                if localProxyDead {
                    try await rebuildDeadLocalProxy()
                    return try await start()
                }
                if state == "Running" {
                    needsRestart = false
                } else if needsRestart {
                    if canRebuildForRecoveryNow {
                        try await rebuildForRecovery()
                        return try await start()
                    }
                    if state == "failed" { throw TailnetError.unavailable }
                }
            }
            if Self.startupStates.contains(state) {
                ensureNodeUp(existing, attempt: attempt)
            }
            return
        }
        let attempt = generation
        let task: Task<TailscaleNode, Error>
        if let startup { task = startup }
        else {
            state = "starting"; message = nil
            diagnostics.recordLink("node", "starting", details: ["proxyMode": proxySettings.mode.rawValue])
            let directory = directory, hostname = hostname, controlURL = controlURL, proxySettings = proxySettings
            task = Task.detached {
                try TailscaleNode.configureProxy(mode: proxySettings.mode.rawValue, address: proxySettings.address)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var protected = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protected.setResourceValues(values)
                let nameFile = directory.appendingPathComponent("node-name")
                let name: String
                if FileManager.default.fileExists(atPath: nameFile.path) { name = try String(contentsOf: nameFile, encoding: .utf8) }
                else {
                    name = hostname + "-" + UUID().uuidString.prefix(6).lowercased()
                    try Data(name.utf8).write(to: nameFile, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nameFile.path)
                }
                let config = Configuration(hostName: name, path: directory.path, authKey: nil,
                    controlURL: controlURL, ephemeral: false)
                return try TailscaleNode(config: config, logger: nil)
            }
            startup = task
        }
        do {
            let created = try await task.value
            // close() owns cleanup of any startup it supersedes.
            guard attempt == generation else { throw CancellationError() }
            if node != nil { return }
            node = created; startup = nil
            diagnostics.recordLink("node", "created")
            ensureNodeUp(created, attempt: attempt)
            ensureWatchRunning(attempt: attempt)
            startPathMonitor(attempt: attempt)
            await refreshStatus()
        } catch {
            if attempt == generation {
                diagnostics.recordLink("node", "creation-failed", error: error)
                startup = nil; state = "failed"; message = String(localized: "无法启动 Tailscale，请重试。")
            }
            throw error
        }
    }

    private func ensureNodeUp(_ target: TailscaleNode, attempt: UUID) {
        guard up == nil, !signingOut, !signedOut, generation == attempt else { return }
        up = Task { [weak self] in
            defer {
                if let self, self.generation == attempt {
                    self.up = nil
                }
            }
            do { try await target.up() }
            catch {
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.diagnostics.recordLink("node", "up-failed", error: error)
                self.needsRestart = true
                self.state = "failed"
                self.message = String(localized: "Tailscale 暂未连接，请重试。")
            }
        }
    }

    func updateProxy(_ settings: TailnetProxySettings) async throws {
        let validated = try settings.validated()
        try validated.save(to: directory)
        proxySettings = validated; proxySettingsError = nil
        // Close only the network node; its saved identity and device pairing stay.
        // The Mac service refresh starts it again if remote access is enabled.
        await close()
    }

    private struct ParsedTailnetStatus: Sendable {
        let backendState: String
        let address: String?
        let authURL: URL?
        let mappedAddresses: Set<String>
        let pacError: Bool
    }

    nonisolated private static func parseStatusJSON(_ data: Data) throws -> ParsedTailnetStatus {
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let peers = status["Peer"] as? [String: [String: Any]]
        let mapped = Set((peers ?? [:]).values.filter { $0["InNetworkMap"] as? Bool == true }
            .flatMap { $0["TailscaleIPs"] as? [String] ?? [] })
        let backendState = status["BackendState"] as? String ?? "starting"
        let resolvedAddress = (status["TailscaleIPs"] as? [String] ?? []).first(where: TailnetEndpoint.isAddress)
        let health = status["Health"] as? [String] ?? []
        let hasPacError = health.contains { $0.localizedCaseInsensitiveContains("PAC") }
        let resolvedAuthURL: URL?
        if let raw = status["AuthURL"] as? String, let url = URL(string: raw),
           url.scheme == "https", url.host == "login.tailscale.com" {
            resolvedAuthURL = url
        } else {
            resolvedAuthURL = nil
        }
        return ParsedTailnetStatus(
            backendState: backendState,
            address: resolvedAddress,
            authURL: resolvedAuthURL,
            mappedAddresses: mapped,
            pacError: hasPacError
        )
    }

    @ObservationIgnored private var lastHealthPacError = false

    func refreshStatus(ignoreFailedRestartGate: Bool = false) async {
        guard let node, ignoreFailedRestartGate || !(needsRestart && state == "failed") else { return }
        let attempt = generation
        do {
            let data = try await node.statusJSON()
            let parsed = try await Task.detached(priority: .utility) {
                try Self.parseStatusJSON(data)
            }.value
            guard attempt == generation else { return }
            mappedAddresses = parsed.mappedAddresses
            lastHealthPacError = parsed.pacError
            diagnostics.recordStatus(data)
            if state != parsed.backendState { state = parsed.backendState }
            if address != parsed.address { address = parsed.address }
            if authURL != parsed.authURL { authURL = parsed.authURL }
            if state == "Running", !needsRestart, message != nil { message = nil }
            if state == "NeedsMachineAuth" {
                let approvalMessage = String(localized: "请在 Tailscale 管理页面允许这台设备加入。")
                if message != approvalMessage { message = approvalMessage }
            }
        } catch {
            if attempt == generation {
                diagnostics.recordLink("node", "status-failed", error: error)
                if state != "failed" { state = "failed" }
                let failedMessage = String(localized: "无法读取连接状态，请重试。")
                if message != failedMessage { message = failedMessage }
                needsRestart = true
            }
        }
    }

    /// Triggers Tailscale's `/localapi/v0/login-interactive` over an isolated `.ephemeral` loopback
    /// session with a short timeout so iOS VPN/PAC proxies or reclaimed loopback listeners can never
    /// wedge `loginURL()` for 60 seconds inside `LocalAPIClient`'s unisolated `.default` URLSession.
    private static func requestLoginInteractive(_ node: TailscaleNode) async -> Bool {
        do {
            let (configuration, loopback) = try await Self.makeTailnetSessionConfiguration(node)
            let probe = URLSession(configuration: configuration, delegate: TailnetNoRedirects(), delegateQueue: nil)
            defer { probe.invalidateAndCancel() }
            guard let url = URL(string: "http://\(loopback.address)/localapi/v0/login-interactive") else {
                return false
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 4
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
            let (_, response) = try await probe.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func loginURL(timeout: Duration = .seconds(30)) async throws -> URL? {
        guard !signingOut else { throw TailnetError.unavailable }
        signedOut = false
        try await start()
        let attempt = generation
        try Task.checkCancellation()
        guard let node else { throw TailnetError.unavailable }
        await refreshStatus()
        for _ in 0..<12 where Self.startupStates.contains(state) && authURL == nil {
            ensureNodeUp(node, attempt: attempt)
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
            await refreshStatus()
        }
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        if state == "Running" { return nil }
        if state == "NeedsMachineAuth" { throw TailnetError.approvalRequired }
        // Reopening the sheet must reuse an already issued login URL.
        if let authURL { return authURL }
        // Fire login-interactive asynchronously so a slow/proxied loopback call NEVER blocks
        // statusJSON() polling (which uses tsnet's in-memory LocalClient and receives AuthURL immediately).
        let interactiveTrigger = Task {
            let sent = await Self.requestLoginInteractive(node)
            if !sent, !Task.isCancelled {
                try? await LocalAPIClient(localNode: node, logger: nil).startLoginInteractive()
            }
        }
        defer { interactiveTrigger.cancel() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            await refreshStatus()
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            if state == "Running" { return nil }
            if state == "NeedsMachineAuth" { throw TailnetError.approvalRequired }
            if state == "failed" { throw TailnetError.unavailable }
            if let authURL { return authURL }
            if lastHealthPacError {
                message = String(localized: "当前系统代理为 PAC 模式，内置 Tailscale 暂不支持。请改为全局/直连代理，或点右上角 ··· 使用「加密中继」。")
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining > .zero { try await Task.sleep(for: min(.milliseconds(300), remaining)) }
        }
        throw TailnetError.loginTimedOut
    }

    func connectedSession(peer: String? = nil, interactive: Bool = false, desktopControl: Bool = false, media: Bool = false) async throws -> URLSession {
        if let peer { diagnostics.observePeer(peer) }
        try await start()
        ensureWatchRunning(attempt: generation)
        let attempt = generation
        let sessionAttempt = sessionGeneration
        if Self.startupStates.contains(state) {
            if let node { ensureNodeUp(node, attempt: attempt) }
            let startupDeadline = ContinuousClock.now.advanced(by: startupTimeout)
            while Self.startupStates.contains(state), ContinuousClock.now < startupDeadline {
                if let node { ensureNodeUp(node, attempt: attempt) }
                try await Task.sleep(for: .milliseconds(200))
                await refreshStatus()
                guard attempt == generation else { throw CancellationError() }
            }
        }
        guard attempt == generation else { throw CancellationError() }
        guard state == "Running", let node else {
            if state == "NeedsLogin" { throw TailnetError.loginRequired }
            if state == "NeedsMachineAuth" { throw TailnetError.approvalRequired }
            // A node wedged in Stopped/Starting/NoState/failed after startup wait
            // must be recycled on the next attempt instead of trapping reconnect forever.
            needsRestart = true
            diagnostics.recordLink("startupWait", "node-unavailable")
            throw URLError(.notConnectedToInternet)
        }
        // Running describes the local node. Its first netmap can still omit the
        // paired Mac. Dialing then can select a route outside the peer tunnel.
        if let peer, !mappedAddresses.contains(peer) {
            await refreshStatus()
            guard attempt == generation else { throw CancellationError() }
            if !mappedAddresses.contains(peer) {
                diagnostics.recordLink("peerMap", "waiting")
                let deadline = ContinuousClock.now.advanced(by: peerMapTimeout)
                while !mappedAddresses.contains(peer) {
                    guard attempt == generation else { throw CancellationError() }
                    guard state == "Running", ContinuousClock.now < deadline else {
                        // A missing remote peer is not evidence that the local listener failed.
                        needsProxyCheck = true
                        diagnostics.recordLink("peerMap", state == "Running" ? "timed-out" : "node-not-running")
                        throw URLError(.notConnectedToInternet)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    await refreshStatus()
                }
                guard attempt == generation else { throw CancellationError() }
            }
        }
        if let peer {
            diagnostics.recordLink("peerMap", "mapped")
            startPeerWarmupIfNeeded(peer, node: node)
            try await awaitPeerWarmupIfRunning(maxWait: .milliseconds(1200))
            guard attempt == generation, sessionAttempt == sessionGeneration else { throw CancellationError() }
        }
        func cached() -> URLSession? { media ? desktopMediaSession : desktopControl ? desktopControlSession : interactive ? interactiveSession : session }
        if let cached = cached() { return cached }
        let (configuration, _) = try await Self.makeTailnetSessionConfiguration(node)
        guard attempt == generation, sessionAttempt == sessionGeneration else { throw CancellationError() }
        // History and uploads must not occupy the chat connection pool.
        if let cached = cached() { return cached }
        configuration.timeoutIntervalForRequest = 45
        configuration.httpMaximumConnectionsPerHost = 6
        let created = URLSession(configuration: configuration, delegate: TailnetNoRedirects(diagnostics: diagnostics), delegateQueue: nil)
        if media { desktopMediaSession = created }
        else if desktopControl { desktopControlSession = created }
        else if interactive { interactiveSession = created } else { session = created }
        return created
    }

    private func ensureWatchRunning(attempt: UUID) {
        guard watch == nil, node != nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == attempt else { return }
                await self.refreshStatus()
                let interval: Duration = self.state == "Running" ? .seconds(6) : .seconds(2)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    private func startPathMonitor(attempt: UUID) {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            let signature = "\(path.status):\(interfaces)"
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                let types = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
                    .filter { path.usesInterfaceType($0) }.map { String(describing: $0) }
                var details = [
                    "interfaces": types.joined(separator: ","), "expensive": String(path.isExpensive),
                    "constrained": String(path.isConstrained)
                ]
                if path.status == .unsatisfied { details["reason"] = String(describing: path.unsatisfiedReason) }
                self.diagnostics.recordLink("networkPath", String(describing: path.status), details: details)
                guard previous != nil, previous != signature else { return }
                if path.status == .unsatisfied {
                    self.invalidateCachedSessions(finishTasks: false)
                }
                if self.node != nil {
                    self.needsProxyCheck = true
                    self.needsPeerWarmup = true
                    self.lastPeerWarmupAt = nil
                    if path.status == .satisfied {
                        // Keep healthy 127.0.0.1 loopback URLSessions alive so WireGuard magicsock roams
                        // seamlessly across Wi-Fi/Cellular/VPN changes without dropping active SSE streams;
                        // verify the loopback listener in the background.
                        await self.checkProxyIfNeeded()
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.momoagent.tailnet.path"))
    }

    private func invalidateCachedSessions(finishTasks: Bool) {
        sessionGeneration = UUID()
        proxyCheck?.cancel(); proxyCheck = nil
        let existing = [session, interactiveSession, desktopControlSession, desktopMediaSession].compactMap { $0 }
        session = nil; interactiveSession = nil; desktopControlSession = nil; desktopMediaSession = nil
        for item in existing {
            if finishTasks { item.finishTasksAndInvalidate() }
            else { item.invalidateAndCancel() }
        }
    }

    private func resumeAllPeerWarmupWaiters() {
        guard !peerWarmupWaiters.isEmpty else { return }
        let waiters = Array(peerWarmupWaiters.values)
        peerWarmupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func cancelPeerWarmupWaiter(_ id: UUID) {
        if let waiter = peerWarmupWaiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }

    private func awaitPeerWarmupIfRunning(maxWait: Duration) async throws {
        guard peerWarmup != nil else { return }
        let budget = min(peerWarmupTimeout, maxWait)
        guard budget > .zero else { return }
        try Task.checkCancellation()
        let waiterID = UUID()
        let deadlineTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: budget)
            self?.cancelPeerWarmupWaiter(waiterID)
        }
        defer { deadlineTimer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if self.peerWarmup == nil || Task.isCancelled {
                    continuation.resume()
                } else {
                    self.peerWarmupWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPeerWarmupWaiter(waiterID)
            }
        }
        try Task.checkCancellation()
    }

    func suspendSessions() {
        diagnostics.recordLink("activity", "suspended")
        watch?.cancel(); watch = nil
        peerWarmup?.cancel(); peerWarmup = nil
        resumeAllPeerWarmupWaiters()
        invalidateCachedSessions(finishTasks: false)
        if node != nil {
            needsProxyCheck = true
            needsPeerWarmup = true
            lastPeerWarmupAt = nil
        }
    }

    func prewarm(peer: String?) {
        guard !signingOut, !signedOut, proxySettingsError == nil else { return }
        Task { [weak self] in
            _ = try? await self?.connectedSession(peer: peer, interactive: true)
        }
    }

    /// Verify and repair any iOS-reclaimed loopback SOCKS5 listener before foreground chat/context streams open.
    func ensureForegroundReady(peer: String? = nil) async {
        diagnostics.recordLink("activity", "foreground-check")
        guard !signingOut, !signedOut, proxySettingsError == nil else { return }
        if let existing = node {
            needsProxyCheck = true
            needsPeerWarmup = true
            lastPeerWarmupAt = nil
            if Self.startupStates.contains(state) {
                ensureNodeUp(existing, attempt: generation)
            }
            ensureWatchRunning(attempt: generation)
            await checkProxyIfNeeded()
            if localProxyDead || (needsRestart && canRebuildForRecoveryNow) {
                try? await start()
            }
            if let peer, TailnetEndpoint.isAddress(peer), state == "Running",
               let currentNode = node, mappedAddresses.contains(peer) {
                startPeerWarmupIfNeeded(peer, node: currentNode)
            }
        } else {
            try? await start()
            if let peer, TailnetEndpoint.isAddress(peer), state == "Running",
               let currentNode = node, mappedAddresses.contains(peer) {
                startPeerWarmupIfNeeded(peer, node: currentNode)
            }
        }
    }

    func prepareForForeground(peer: String? = nil) {
        diagnostics.recordLink("activity", "foreground-check")
        // iOS can reclaim the SOCKS listener while suspended even if LocalAPI says Running.
        // A brief inactive scene does not mean that listener was reclaimed.
        if let existing = node {
            needsProxyCheck = true
            needsPeerWarmup = true
            lastPeerWarmupAt = nil
            if Self.startupStates.contains(state) {
                ensureNodeUp(existing, attempt: generation)
            }
            ensureWatchRunning(attempt: generation)
            if let peer, TailnetEndpoint.isAddress(peer) {
                let attempt = generation
                Task { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    await self.checkProxyIfNeeded()
                    guard self.generation == attempt, self.state == "Running",
                          let currentNode = self.node, self.mappedAddresses.contains(peer) else { return }
                    self.startPeerWarmupIfNeeded(peer, node: currentNode)
                }
            }
        }
    }

    func restartForRecovery() async {
        guard !signingOut, !signedOut else { return }
        try? await rebuildForRecovery()
    }

    private func rebuildForRecovery() async throws {
        if let lastRecoveryRestart, lastRecoveryRestart.duration(to: .now) < recoveryRestartInterval { throw TailnetError.unavailable }
        lastRecoveryRestart = .now
        await close()
    }

    private func owns(_ pool: URLSession) -> Bool {
        pool === session || pool === interactiveSession || pool === desktopControlSession || pool === desktopMediaSession
    }

    func dataTask(for request: URLRequest, using pool: URLSession) throws -> URLSessionDataTask {
        // Foundation raises an Objective-C exception if a task is created after invalidation.
        // Check ownership and create the task together on the same actor that retires pools.
        guard owns(pool) else { throw URLError(.networkConnectionLost) }
        return pool.dataTask(with: request)
    }

    private static func makeTailnetSessionConfiguration(_ node: TailscaleNode) async throws -> (URLSessionConfiguration, (address: String, localAPIKey: String)) {
        // Use .ephemeral rather than .default so CFNetwork never shares global cookie/credential
        // state or dynamic system-proxy mutations with the private loopback SOCKS5 session.
        let configuration = URLSessionConfiguration.ephemeral
        let loopback = try await configuration.proxyVia(node)
        Self.isolateTailnetProxyConfiguration(configuration)
        return (configuration, (address: loopback.address, localAPIKey: loopback.localAPIKey))
    }

    private static func isolateTailnetProxyConfiguration(_ configuration: URLSessionConfiguration) {
        // Leave connectionProxyDictionary nil: in CFNetwork, a non-nil empty dictionary ([:]) overrides
        // proxyConfigurations with an explicit DIRECT proxy table and bypasses Tailscale's loopback SOCKS5
        // ProxyConfiguration into ATS -1022, whereas nil preserves proxyConfigurations with failover disabled.
        configuration.connectionProxyDictionary = nil
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        var proxies = configuration.proxyConfigurations
        for i in proxies.indices { proxies[i].allowFailover = false }
        configuration.proxyConfigurations = proxies
    }

    func failedRequest(_ error: Error, session failedSession: URLSession) {
        guard owns(failedSession) else { return }
        guard !AgentTransportFailure.isCancelled(error) else { return }
        let nsError = error as NSError
        let shouldInvalidate: Bool
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            shouldInvalidate = [
                .badURL, .timedOut, .cannotConnectToHost, .networkConnectionLost,
                .notConnectedToInternet, .appTransportSecurityRequiresSecureConnection
            ].contains(code)
        } else {
            shouldInvalidate = AgentTransportFailure.isSocketOrLinkFailure(error)
        }
        guard shouldInvalidate else { return }
        if failedSession === session { session = nil }
        if failedSession === interactiveSession { interactiveSession = nil }
        if failedSession === desktopControlSession { desktopControlSession = nil }
        if failedSession === desktopMediaSession { desktopMediaSession = nil }
        failedSession.finishTasksAndInvalidate()
        needsProxyCheck = true
        needsPeerWarmup = true
    }

    private enum PeerPingOutcome: Sendable {
        case reachable
        case retryableFailure
        case unsupported
    }

    private func startPeerWarmupIfNeeded(_ peer: String, node: TailscaleNode) {
        guard peerWarmup == nil, needsPeerWarmup, TailnetEndpoint.isAddress(peer) else { return }
        if let last = lastPeerWarmupAt, last.duration(to: .now) < .seconds(5) {
            needsPeerWarmup = false
            return
        }
        needsPeerWarmup = false
        lastPeerWarmupAt = .now
        let timeout = peerWarmupTimeout
        let diagnostics = self.diagnostics
        // The mapped peer can accept HTTP while discovery looks for a faster route.
        peerWarmup = Task { [weak self] in
            defer {
                // Suspension can replace this task without replacing the node.
                if !Task.isCancelled { self?.peerWarmup = nil }
                self?.resumeAllPeerWarmupWaiters()
            }
            do {
                try Task.checkCancellation()
                let (configuration, loopback) = try await Self.makeTailnetSessionConfiguration(node)
                let probe = URLSession(configuration: configuration, delegate: TailnetNoRedirects(), delegateQueue: nil)
                defer { probe.invalidateAndCancel() }
                let loopbackAddress = loopback.address
                let auth = "Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString()
                let encodedPeer = peer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? peer
                @Sendable func ping(_ kind: String, limit: TimeInterval) async -> PeerPingOutcome {
                    guard let url = URL(string: "http://\(loopbackAddress)/localapi/v0/ping?ip=\(encodedPeer)&type=\(kind)") else {
                        return .unsupported
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = limit
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue(auth, forHTTPHeaderField: "Authorization")
                    request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
                    let data: Data, response: URLResponse
                    do { (data, response) = try await probe.data(for: request) }
                    catch {
                        if !Task.isCancelled { diagnostics.recordLink(kind, "probe-request-failed", error: error) }
                        return .unsupported
                    }
                    guard let http = response as? HTTPURLResponse else {
                        diagnostics.recordLink(kind, "invalid-response")
                        return .unsupported
                    }
                    guard http.statusCode == 200,
                          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        diagnostics.recordLink(kind, "invalid-response", details: ["http": String(http.statusCode)])
                        return .unsupported
                    }
                    let err = payload["Err"] as? String ?? ""
                    let route: String
                    if (payload["DERPRegionID"] as? Int ?? 0) > 0 { route = "derp" }
                    else if !(payload["Endpoint"] as? String ?? "").isEmpty { route = "direct" }
                    else { route = "unknown" }
                    diagnostics.recordLink(kind, err.isEmpty ? "reachable" : "peer-error",
                                           details: err.isEmpty ? ["route": route] : [:])
                    return err.isEmpty ? .reachable : .retryableFailure
                }
                let seconds = max(0.2, Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
                // Wake magicsock DERP + direct UDP discovery and confirm WireGuard tunnel readiness
                // via LocalAPI before dialing through tsnet's 5-second SOCKS5 connect cutoff.
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        _ = await ping("disco", limit: min(2.5, seconds))
                        return false
                    }
                    group.addTask {
                        switch await ping("TSMP", limit: max(0.2, seconds * 0.65)) {
                        case .reachable, .unsupported:
                            return true
                        case .retryableFailure:
                            guard !Task.isCancelled else { return true }
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled else { return true }
                            _ = await ping("TSMP", limit: max(0.2, seconds * 0.45))
                            return true
                        }
                    }
                    group.addTask {
                        do { try await Task.sleep(for: timeout) }
                        catch { return false }
                        diagnostics.recordLink("peerWarmup", "deadline")
                        return true
                    }
                    while let finished = await group.next() {
                        if finished {
                            group.cancelAll()
                            break
                        }
                    }
                }
            } catch {
                if !Task.isCancelled { diagnostics.recordLink("peerWarmup", "setup-failed", error: error) }
            }
        }
    }

    private func checkProxyIfNeeded() async {
        if let proxyCheck { await proxyCheck.value; return }
        guard needsProxyCheck, let node else { return }
        needsProxyCheck = false
        let attempt = generation
        let sessionAttempt = sessionGeneration
        let task = Task { [weak self] in
            do {
                let (configuration, loopback) = try await Self.makeTailnetSessionConfiguration(node)
                let probe = URLSession(configuration: configuration, delegate: TailnetNoRedirects(), delegateQueue: nil)
                defer { probe.invalidateAndCancel() }
                var request = URLRequest(url: URL(string: "http://\(loopback.address)/localapi/v0/status")!)
                request.timeoutInterval = 3
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Basic " + Data("tsnet:\(loopback.localAPIKey)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
                let (data, response) = try await probe.data(for: request)
                guard !Task.isCancelled, self?.generation == attempt, self?.sessionGeneration == sessionAttempt else {
                    if self?.generation == attempt { self?.needsProxyCheck = true }
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode
                guard code == 200 else {
                    self?.diagnostics.recordLink("localProxyHTTP", "unexpected-response",
                                                 details: ["http": code.map(String.init) ?? "none"])
                    throw URLError(.cannotConnectToHost)
                }
                self?.localProxyDead = false
                self?.diagnostics.recordLink("localProxy", "reachable")
                if let self, self.generation == attempt,
                   let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let backendState = status["BackendState"] as? String {
                    self.state = backendState
                    if backendState == "Running" {
                        self.needsRestart = false
                    } else if Self.startupStates.contains(backendState) {
                        self.ensureNodeUp(node, attempt: attempt)
                    }
                }
            } catch {
                if !Task.isCancelled, !AgentTransportFailure.isCancelled(error),
                   self?.generation == attempt, self?.sessionGeneration == sessionAttempt {
                    let repairable = AgentTransportFailure.isSocketOrLinkFailure(error)
                    self?.diagnostics.recordLink("localProxy", repairable ? "restart-required" : "check-failed", error: error)
                    if repairable {
                        self?.localProxyDead = true
                        self?.needsRestart = true
                    }
                } else if self?.generation == attempt {
                    self?.needsProxyCheck = true
                }
            }
        }
        proxyCheck = task
        await task.value
        if generation == attempt, sessionGeneration == sessionAttempt { proxyCheck = nil }
    }

    func close() async {
        if let closing { await closing.value; return }
        diagnostics.recordLink("node", "closing")
        generation = UUID(); watch?.cancel(); watch = nil; up?.cancel(); up = nil
        pathMonitor?.cancel(); pathMonitor = nil; lastPathSignature = nil
        needsRestart = false; localProxyDead = false; needsProxyCheck = false
        peerWarmup?.cancel(); peerWarmup = nil; needsPeerWarmup = true; lastPeerWarmupAt = nil
        resumeAllPeerWarmupWaiters()
        invalidateCachedSessions(finishTasks: false)
        let pending = startup
        let old = node; node = nil; startup = nil
        state = "stopped"; authURL = nil; address = nil; mappedAddresses.removeAll()
        let cleanup = Task {
            if let old { try? await old.close() }
            else if let pending, let created = try? await pending.value { try? await created.close() }
        }
        closing = cleanup
        await cleanup.value
        if closing == cleanup { closing = nil }
    }

    func logout() async throws {
        guard !signingOut else { return }
        try await start()
        signingOut = true
        defer { signingOut = false }
        session?.invalidateAndCancel(); session = nil
        interactiveSession?.invalidateAndCancel(); interactiveSession = nil
        desktopControlSession?.invalidateAndCancel(); desktopControlSession = nil
        desktopMediaSession?.invalidateAndCancel(); desktopMediaSession = nil
        if let node { try await node.logout() }
        signedOut = true
        await close(); message = nil
    }

}

enum TailnetError: LocalizedError, TransientTransportError {
    case unavailable, loginRequired, loginUnavailable, loginTimedOut, approvalRequired, invalidEndpoint
    var isTransientTransportFailure: Bool {
        switch self {
        case .unavailable, .loginTimedOut: true
        case .loginRequired, .loginUnavailable, .approvalRequired, .invalidEndpoint: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "连接暂不可用，请重试。")
        case .loginRequired: String(localized: "请先在 MoMo Agent 中登录 Tailscale。")
        case .loginUnavailable: String(localized: "无法打开登录窗口，请重试。")
        case .loginTimedOut: String(localized: "连接 Tailscale 超时，请稍后重试。")
        case .approvalRequired: String(localized: "请在 Tailscale 管理页面允许这台设备加入。")
        case .invalidEndpoint: String(localized: "连接地址已失效，请在 Mac 重新扫码配对。")
        }
    }
}

private final class TailnetNoRedirects: NSObject, URLSessionTaskDelegate {
    private let diagnostics: TailnetDiagnostics?
    init(diagnostics: TailnetDiagnostics? = nil) { self.diagnostics = diagnostics }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        diagnostics?.record(metrics, request: task.originalRequest)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { diagnostics?.recordFailure(error, request: task.originalRequest) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
