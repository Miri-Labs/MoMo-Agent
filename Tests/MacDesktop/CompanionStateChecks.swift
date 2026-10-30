import Foundation
import CoreGraphics
import MoMoAgentClient

@main
enum CompanionStateChecks {
    static func decode<T: Decodable>(_ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func run(_ id: String, state: String = "running", work: String? = nil, extra: [String: Any] = [:]) throws -> AgentRun {
        var value: [String: Any] = ["run_id": id, "status": state, "title": "整理录音"]
        value["work_id"] = work
        value.merge(extra) { _, new in new }
        return try decode(value)
    }
    static func child(_ id: String, state: String = "running", report: String = "pending", work: String? = nil, extra: [String: Any] = [:]) throws -> ConversationWork {
        var value: [String: Any] = ["id": id, "state": state, "report_state": report, "title": "子任务"]
        value["work_id"] = work
        value.merge(extra) { _, new in new }
        return try decode(value)
    }
    static func main() throws {
        let parent = try run("r1", work: "w1")
        let process = try child("p1", work: "w1")
        let delegation = try child("d1", work: "w1")
        let grouped = DesktopCompanionState(prepared: true, online: true, runs: [parent], work: [process, delegation])
        precondition(grouped.items.count == 1 && grouped.badge == "1" && grouped.items[0].title == "整理录音")
        precondition(grouped.working && !grouped.needsAttention)

        let waiting = try run("r2", work: "w2", extra: ["wait_reason": "computer_human"])
        let priority = DesktopCompanionState(prepared: true, online: true, runs: [parent, waiting])
        precondition(priority.items.first?.id == "w2" && priority.needsAttention && priority.badge == "2")
        let waitingOnly = DesktopCompanionState(prepared: true, online: true, runs: [waiting])
        precondition(!waitingOnly.working && waitingOnly.subtitle == "有事等你看看")
        let approval = try run("r3", extra: ["pending_controls": [["prompt_id": "a1", "kind": "approval"]]])
        precondition(DesktopCompanionState(prepared: true, online: true, runs: [approval]).needsAttention)

        let finished = try run("r1", state: "completed", work: "w1")
        let reported = try child("p1", state: "completed", report: "reported", work: "w1")
        precondition(DesktopCompanionState(prepared: true, online: true, runs: [finished], work: [reported]).items.isEmpty)
        let blocked = try child("p1", state: "completed", report: "blocked", work: "w1")
        let blockedResult = DesktopCompanionState(prepared: true, online: true, runs: [finished], work: [blocked])
        precondition(blockedResult.needsAttention && !blockedResult.working && blockedResult.items[0].title == "整理录音")

        let offline = DesktopCompanionState(prepared: true, online: false, runs: [parent])
        precondition(offline.badge == nil && !offline.working && offline.items.count == 1 && offline.subtitle == "暂时离线")
        precondition(DesktopCompanionState(prepared: false, online: false).subtitle == "开始设置")
        precondition(DesktopCompanionState(prepared: true, online: true).subtitle == "我在，随时找我")
        let many = try (0..<12).map { try run("r\($0)") }
        precondition(DesktopCompanionState(prepared: true, online: true, runs: many).badge == "9+")
        let unknown = try run("r3", state: "unexpected_future_state")
        precondition(DesktopCompanionState(prepared: true, online: true, runs: [unknown]).needsAttention)
        let stopping = try run("r4", extra: ["cancel_requested": true])
        precondition(DesktopCompanionState(prepared: true, online: true, runs: [stopping]).items.first?.phase == .stopping)

        let local: RemoteTask = try decode(["id": UUID().uuidString, "sessionID": "s1", "input": "整理录音", "createdAt": 0,
            "needsReview": false, "stopRequested": false, "run": ["run_id": "r1", "status": "running", "work_id": "w1"]])
        precondition(DesktopCompanionState(prepared: true, online: true, runs: [parent], work: [process], tasks: [local]).items.count == 1)
        precondition(DesktopCompanionState(prepared: true, online: true, work: [blocked], tasks: [local]).items.first?.phase == .attention)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let notch = DesktopNotchLayout(screen: screen, safeTop: 38,
            left: CGRect(x: 0, y: 1162, width: 860, height: 38), right: CGRect(x: 1060, y: 1162, width: 860, height: 38))!
        precondition(notch.notch.width == 200 && notch.compactFrame.midX == 960)
        precondition(notch.compactFrame.maxY == screen.maxY && notch.compactFrame.height == 38)
        precondition(notch.expandedFrame(contentHeight: 220).maxY == screen.maxY)
        precondition(notch.expandedFrame(contentHeight: 220).height == 258 && notch.topPadding == 38)
        let external = DesktopNotchLayout(screen: CGRect(x: -1920, y: -1080, width: 1920, height: 1080), safeTop: 0, left: nil, right: nil)
        precondition(external == nil, "No physical notch means a native menu-bar item, never a simulated notch")
        precondition(DesktopNotchLayout(screen: screen, safeTop: 38, left: nil, right: nil) == nil)
        let offset = DesktopNotchLayout(screen: screen.offsetBy(dx: -1920, dy: -1200), safeTop: 38,
            left: CGRect(x: -1920, y: -38, width: 860, height: 38), right: CGRect(x: -860, y: -38, width: 860, height: 38))!
        precondition(offset.compactFrame.midX == -960 && offset.compactFrame.maxY == 0)
        precondition(offset.screen.contains(offset.expandedFrame(contentHeight: 2000)))
        print("Companion state checks passed: grouping, priorities, waiting, completion, reporting, offline, unknown, cancellation and local replay")
        print("Notch layout checks passed: camera exclusion, expansion anchor, external screen and negative screen origin")
    }
}
