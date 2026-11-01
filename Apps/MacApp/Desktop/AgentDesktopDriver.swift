import Foundation
import Darwin

/// The dylib runs in MoMo's permission identity. All calls are serialized off the UI thread.
final class AgentDesktopDriver: @unchecked Sendable {
    private let mutex = NSLock()
    private let libraryURL: URL
    private var library: UnsafeMutableRawPointer?
    private var adapter: OpaquePointer?
    private var owner: Data?
    private var session = ""
    private var stateRoot: URL?

    init(libraryURL: URL = Bundle.main.resourceURL!.appendingPathComponent("AgentDesktop/libagent_desktop_ffi.dylib")) {
        self.libraryURL = libraryURL
    }

    private func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let library, let pointer = dlsym(library, name) else { throw failure("电脑组件缺少 \(name)，请更新应用。") }
        return unsafeBitCast(pointer, to: type)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "MoMo.AgentDesktop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func lastError() -> Error {
        let read = try? symbol("ad_last_error_message", as: (@convention(c) () -> UnsafePointer<CChar>?).self)
        return failure(read?().map { String(cString: $0) } ?? "电脑组件未能完成操作。")
    }

    private func prepare(owner: Data) throws -> OpaquePointer {
        if library == nil {
            guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { throw failure("内置电脑组件不可用，请重新构建或更新应用。") }
            library = handle
            do {
                let initialize = try symbol("ad_init", as: (@convention(c) (UInt32) -> Int32).self)
                let size = try symbol("ad_action_size", as: (@convention(c) () -> Int).self)
                guard initialize(UInt32(AD_ABI_VERSION_MAJOR)) == 0, size() == MemoryLayout<AdAction>.size else {
                    throw failure("电脑组件版本不匹配，请更新应用。")
                }
            } catch { dlclose(handle); library = nil; throw error }
        }
        if self.owner != owner || adapter == nil {
            destroyAdapter()
            let create = try symbol("ad_adapter_create_with_session", as: (@convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?).self)
            session = "momo-" + UUID().uuidString
            adapter = session.withCString { create($0) }
            guard adapter != nil else { throw lastError() }
            self.owner = owner
        }
        return adapter!
    }

    private func destroyAdapter() {
        if let adapter, let destroy = try? symbol("ad_adapter_destroy", as: (@convention(c) (OpaquePointer?) -> Void).self) { destroy(adapter) }
        adapter = nil; owner = nil
        if !session.isEmpty, let stateRoot {
            // Only this adapter's UUID directory; never remove another agent-desktop session.
            try? FileManager.default.removeItem(at: stateRoot.appendingPathComponent("sessions").appendingPathComponent(session))
        }
        session = ""
    }

    deinit {
        destroyAdapter()
        // Rust/AppKit initialization installs process-lifetime callbacks; do not dlclose a used image.
    }

    private func admitted(_ request: [String: Any], directory: URL, mutation: Bool) throws -> Data {
        let lease = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("lease.json"))) as? [String: Any]
        guard request["actor"] as? String == "agent", lease?["owner"] as? String == "agent",
              let control = request["control"] as? [String: Any], let work = lease?["agent_work"] as? [String: Any],
              let epoch = control["epoch"] as? Int, epoch == lease?["epoch"] as? Int,
              let workID = control["work_id"] as? String, workID == work["work_id"] as? String,
              let runID = control["run_id"] as? String, runID == work["run_id"] as? String,
              let generation = control["generation"] as? Int, generation == work["generation"] as? Int else {
            throw failure("电脑控制权已变化，请等待用户交还控制权后重新读取。")
        }
        if mutation, lease?["observed_epoch"] as? Int != epoch { throw failure("请先重新读取电脑界面，再决定操作。") }
        return try JSONSerialization.data(withJSONObject: control, options: .sortedKeys)
    }

    func perform(_ payload: Data, directory: URL) throws -> Data {
        mutex.lock(); defer { mutex.unlock() }
        guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let op = request["op"] as? String, ["accessibility-snapshot", "accessibility-action"].contains(op) else { throw failure("无效的电脑请求。") }
        let mutation = op == "accessibility-action"
        // Serialize a single dispatch with phone takeover. No pre-action waits/retries while holding the lease.
        let lock = mutation ? open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR, 0o600) : -1
        if mutation { guard lock >= 0 else { throw failure("无法读取电脑控制权。") }; flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        let control = try admitted(request, directory: directory, mutation: mutation)
        if library == nil {
            let root = directory.appendingPathComponent("agent-desktop")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard setenv("AGENT_DESKTOP_HOME", root.path, 1) == 0 else { throw failure("无法初始化电脑组件存储。") }
            stateRoot = root
        }
        let adapter = try prepare(owner: control)
        let freeString = try symbol("ad_free_string", as: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self)
        var output: UnsafeMutablePointer<CChar>?
        defer { if let output { freeString(output) } }
        if mutation {
            guard let event = request["event"] as? [String: Any], let kind = event["action"] as? String,
                  let ref = event["ref"] as? String, ref.range(of: "^@[A-Za-z0-9_-]+:e[0-9]+$", options: .regularExpression) != nil else { throw failure("请使用本次界面快照中的完整控件编号。") }
            let kinds: [String: Int32] = ["click": 0, "double_click": 1, "right_click": 2, "set_value": 4, "focus": 5,
                "expand": 6, "collapse": 7, "select": 8, "toggle": 9, "check": 10, "uncheck": 11,
                "scroll": 12, "scroll_to": 13, "press_key": 14, "type_text": 17, "clear": 18, "hover": 19]
            guard let value = kinds[kind] else { throw failure("不支持的控件操作。") }
            let text = event["text"] as? String ?? "", key = event["key"] as? String ?? ""
            guard !text.contains("\0"), !key.contains("\0") else { throw failure("操作内容包含无效字符。") }
            let directions: [String: Int32] = ["up": 0, "down": 1, "left": 2, "right": 3]
            let modifiers: [String: Int32] = ["meta": 0, "ctrl": 1, "alt": 2, "shift": 3]
            let names = event["modifiers"] as? [String] ?? []
            let values = names.compactMap { modifiers[$0] }
            let amount = event["amount"] as? Int ?? 3
            guard names.count == values.count, names.count <= 4, (1...100).contains(amount),
                  let direction = directions[event["direction"] as? String ?? "down"] else { throw failure("无效的键盘或滚动参数。") }
            let execute = try symbol("ad_execute_by_ref_timeout", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<AdAction>?, Int32, Int64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32).self)
            _ = ref.withCString { reference in text.withCString { textPointer in key.withCString { keyPointer in
                values.withUnsafeBufferPointer { buffer in
                    var action = AdAction()
                    action.kind = value; action.text = textPointer
                    action.key.key = keyPointer; action.key.modifiers = buffer.baseAddress; action.key.modifier_count = UInt32(buffer.count)
                    action.scroll.direction = direction; action.scroll.amount = UInt32(amount)
                    return execute(adapter, reference, &action, event["headed"] as? Bool == true ? 2 : 0, 0, &output)
                }
            } } }
        } else {
            let snapshot = try symbol("ad_snapshot", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UInt8, Bool, Bool, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32).self)
            let app = request["app"] as? String ?? ""
            guard !app.contains("\0"), app.utf8.count <= 512 else { throw failure("应用名称无效。") }
            let depth = UInt8(min(20, max(1, request["depth"] as? Int ?? 10)))
            _ = app.withCString { snapshot(adapter, app.isEmpty ? nil : $0, 0, depth, false, false, &output) }
        }
        guard let output else { throw lastError() }
        let result = Data(String(cString: output).utf8)
        guard result.count < 2_800_000 else { throw failure("界面内容过多，请降低 depth 后重新读取；本次结果未返回。") }
        guard try admitted(request, directory: directory, mutation: false) == control else { throw failure("电脑控制权已变化。") }
        return result
    }
}
