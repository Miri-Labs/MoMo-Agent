// Compile with DesktopModelConnection.swift; the production process and login lifecycle run unchanged.
import Foundation

@MainActor final class DesktopModel {
    struct Status { let agentOnline: Bool }
    let repository: URL
    let dataDirectory: URL
    var isPrepared = true
    var busy: String?
    var failure: String?
    var status: Status?
    var modelProvider = DesktopModelProvider.codex
    var modelAccount: DesktopModelAccount?
    var loadingModelAccount = false
    var modelAccountCheckedAt: Date?
    var modelAccountRefreshTask: Task<Void, Never>?
    var modelAccountRefreshID: UUID?
    var modelConnectionCancelled = false
    var modelLogin: DesktopModelLogin?
    var modelLoginTask: Task<Void, Never>?
    var modelProcess: Process?
    var modelName = ""
    init(_ directory: URL) { repository = directory; dataDirectory = directory }
    func startAndContinue() async { assertionFailure("Authentication must not start an agent") }
    func startAgent() async { assertionFailure("Authentication must not start an agent") }
}

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

@main struct ModelLoginProbe {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Login did not make progress")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("momo-auth-probe-" + UUID().uuidString)
        let bin = directory.appendingPathComponent("runtime/venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let python = bin.appendingPathComponent("python")
        let fixture = #"""
#!/usr/bin/python3
import json, pathlib, signal, sys, time
data = pathlib.Path(sys.argv[sys.argv.index('--data-dir') + 1])
mode = (data / 'mode').read_text()
command = next(x for x in sys.argv if x in ('status', 'login', 'verify'))
if command == 'status':
    with (data / 'status-count').open('a') as output: output.write('1\n')
    time.sleep(0.2)
account = dict(provider='codex', connected=command == 'login', models=['test-model'], loginAvailable=True)
if command == 'login':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    url = 'https://evil.invalid/oauth/authorize' if mode == 'hostile' else 'https://auth.openai.com/codex/device'
    print(json.dumps(dict(event='authorization', url=url, code='TEST-1234', expiresAt=time.time()+300)), flush=True)
    time.sleep(0.2 if mode in ('success', 'malformed') else 30)
    if mode == 'malformed':
        print('not-json', flush=True)
        sys.exit(0)
print(json.dumps(account), flush=True)
"""#
        try fixture.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        let mode = directory.appendingPathComponent("mode")
        try "hang".write(to: mode, atomically: true, encoding: .utf8)
        let model = DesktopModel(directory)
        model.beginModelLogin()
        try await wait { model.modelLogin?.code == "TEST-1234" }
        precondition(model.busy == nil, "Browser wait must not lock the application")
        let oldID = model.modelLogin!.id, oldProcess = model.modelProcess!
        let cancelledAt = ContinuousClock.now
        model.cancelModelConnection()
        precondition(model.modelLogin == nil && model.modelProcess == nil)
        precondition(ContinuousClock.now - cancelledAt < .milliseconds(100), "Cancel must release UI immediately")

        try "success".write(to: mode, atomically: true, encoding: .utf8)
        model.beginModelLogin()
        precondition(model.modelLogin?.id != oldID)
        try await wait { model.subscriptionConnected && model.modelLogin == nil }
        try await wait { !oldProcess.isRunning }
        precondition(model.modelAccount?.models == ["test-model"], "Cancelled result replaced the new account")

        try "hang".write(to: mode, atomically: true, encoding: .utf8)
        do {
            _ = try await model.modelCommand("login", provider: .codex, timeout: 0.15)
            preconditionFailure("A stalled login must time out")
        } catch { precondition(error.localizedDescription == "登录已超时，请重试。") }
        precondition(model.modelProcess == nil)

        try "malformed".write(to: mode, atomically: true, encoding: .utf8)
        do {
            _ = try await model.modelCommand("login", provider: .codex)
            preconditionFailure("Malformed results must not count as signed in")
        } catch { precondition(error.localizedDescription == "模型连接没有完成，请重试。") }

        try "hostile".write(to: mode, atomically: true, encoding: .utf8)
        model.modelAccount = nil
        model.beginModelLogin()
        try await Task.sleep(for: .milliseconds(300))
        precondition(model.modelLogin?.authorizationURL == nil, "Untrusted authorization URL reached the UI")
        let hostileProcess = model.modelProcess!
        model.cancelModelConnection()
        try await wait { !hostileProcess.isRunning }
        let count = directory.appendingPathComponent("status-count")
        try "".write(to: count, atomically: true, encoding: .utf8)
        model.modelName = "configured-model-outside-fallback-catalog"
        let viewRefresh = Task { await model.refreshModelAccount() }
        try await wait { model.loadingModelAccount }
        viewRefresh.cancel() // Closing Settings does not own or cancel the refresh.
        await model.refreshModelAccount()
        precondition(model.modelAccount != nil && !model.loadingModelAccount)
        precondition(model.modelName == "configured-model-outside-fallback-catalog")
        await model.refreshModelAccount()
        precondition((try? String(contentsOf: count, encoding: .utf8)) == "1\n", "Repeated opens spawned duplicate status processes")
        await model.refreshModelAccount(force: true)
        precondition((try? String(contentsOf: count, encoding: .utf8)) == "1\n1\n")
        model.modelAccountCheckedAt = .distantPast
        await model.refreshModelAccount()
        precondition((try? String(contentsOf: count, encoding: .utf8)) == "1\n1\n1\n")
        let oldRefresh = Task { await model.refreshModelAccount(force: true) }
        try await wait { model.loadingModelAccount }
        model.cancelModelConnection(); model.modelProvider = .api; model.modelAccount = nil
        await oldRefresh.value
        precondition(model.modelAccount == nil && !model.loadingModelAccount, "Cancelled provider refresh replaced current configuration")
        print("PASS: shared model refresh, view cancellation, five-minute cache, expiry, forced refresh, configured model preservation")
        print("PASS: streamed code, nonblocking wait, immediate cancel, retry isolation, bounded timeout, URL validation, malformed result handling, forced child cleanup")
    }
}
