import Foundation

/// Runs against the actual bundled FFI without reading or operating a user's applications.
@main struct AgentDesktopSmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("momo-ad-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control: [String: Any] = ["work_id": "fixture", "run_id": "run-1", "generation": 1, "epoch": 4]
        let work = control.filter { $0.key != "epoch" }
        func writeLease(_ owner: String, observed: Bool) throws {
            var lease: [String: Any] = ["owner": owner, "epoch": 4, "agent_work": work]
            if observed { lease["observed_epoch"] = 4 }
            try JSONSerialization.data(withJSONObject: lease).write(to: directory.appendingPathComponent("lease.json"), options: .atomic)
        }
        let driver = AgentDesktopDriver(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let snapshot: [String: Any] = ["actor": "agent", "control": control, "op": "accessibility-snapshot", "app": "com.momoagent.nonexistent-" + UUID().uuidString]
        let payload = try JSONSerialization.data(withJSONObject: snapshot)
        try writeLease("human", observed: true)
        do { _ = try driver.perform(payload, directory: directory); fatalError("human takeover was bypassed") } catch { print("human takeover: blocked") }
        try writeLease("agent", observed: false)
        let action: [String: Any] = ["actor": "agent", "control": control, "op": "accessibility-action", "event": ["ref": "@sfixture:e1", "action": "click"]]
        do { _ = try driver.perform(JSONSerialization.data(withJSONObject: action), directory: directory); fatalError("unobserved action was dispatched") } catch { print("unobserved action: blocked") }
        let result = try JSONSerialization.jsonObject(with: driver.perform(payload, directory: directory)) as! [String: Any]
        precondition(result["ok"] as? Bool == false && result["error"] != nil)
        print("pinned FFI ABI + snapshot error envelope: OK")
        try writeLease("agent", observed: true)
        let stale = try JSONSerialization.jsonObject(with: driver.perform(JSONSerialization.data(withJSONObject: action), directory: directory)) as! [String: Any]
        precondition(stale["ok"] as? Bool == false && stale["error"] != nil)
        print("unobserved ref cannot dispatch: OK")
    }
}
