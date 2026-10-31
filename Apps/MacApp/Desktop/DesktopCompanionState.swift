import Foundation
import MoMoAgentClient

struct DesktopCompanionState: Equatable {
    enum Phase: Int, Comparable {
        case reporting, queued, running, stopping, waiting, attention
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        var label: String {
            switch self {
            case .reporting: String(localized: "正在汇总")
            case .queued: String(localized: "排队中")
            case .running: String(localized: "进行中")
            case .stopping: String(localized: "正在停止")
            case .waiting: String(localized: "等你确认")
            case .attention: String(localized: "需要查看")
            }
        }
        var symbol: String {
            switch self {
            case .reporting: "text.bubble"
            case .queued: "clock"
            case .running: "ellipsis"
            case .stopping: "stop"
            case .waiting: "hand.raised"
            case .attention: "exclamationmark"
            }
        }
    }
    struct Item: Identifiable, Equatable {
        let id: String
        var title: String
        var phase: Phase
    }
    let prepared: Bool
    let online: Bool
    let items: [Item]
    var needsAttention: Bool { items.contains { $0.phase >= .waiting } }
    var working: Bool { online && items.contains { $0.phase == .running || $0.phase == .reporting } }
    var badge: String? { online && !items.isEmpty ? (items.count > 9 ? "9+" : String(items.count)) : nil }
    var subtitle: String {
        if !prepared { return String(localized: "开始设置") }
        if !online { return String(localized: "暂时离线") }
        if needsAttention { return String(localized: "有事等你看看") }
        if !items.isEmpty { return String(localized: "\(items.count) 项任务进行中") }
        return String(localized: "我在，随时找我")
    }

    init(prepared: Bool, online: Bool, runs: [AgentRun] = [], work: [ConversationWork] = [], tasks: [RemoteTask] = []) {
        self.prepared = prepared
        self.online = online
        var merged: [String: Item] = [:]
        func insert(id: String, title: String, phase: Phase) {
            if let previous = merged[id] {
                merged[id]?.phase = max(previous.phase, phase)
            } else { merged[id] = Item(id: id, title: title, phase: phase) }
        }
        for run in runs where !run.isTerminal {
            let phase: Phase = run.cancelRequested == true ? .stopping
                : run.pendingControls?.isEmpty == false || run.waitReason == "computer_human" ? .waiting
                : run.status == "queued" || run.waitReason == "computer_task" ? .queued
                : ["running", "started"].contains(run.status) ? .running : .attention
            insert(id: run.workID ?? run.runID, title: run.title ?? String(localized: "正在处理你的消息"), phase: phase)
        }
        for child in work where child.isPending {
            let parent = runs.first { (child.workID != nil && $0.workID == child.workID) || $0.runID == child.originRunID }
            let phase: Phase
            if child.cancelRequested == true && !["completed", "failed", "cancelled", "unknown"].contains(child.state) { phase = .stopping }
            else if child.waitReason == "computer_human" { phase = .waiting }
            else if ["failed", "unknown"].contains(child.state) || ["failed", "unknown", "blocked"].contains(child.reportState) { phase = .attention }
            else if child.waitReason == "computer_task" || child.state == "queued" { phase = .queued }
            else if ["running", "finalizing", "stalling"].contains(child.state) { phase = .running }
            else { phase = .reporting }
            // A run, its shell process and its delegated workers are one user task.
            let resolvedTitle: String = {
                if let parentTitle = parent?.title, !parentTitle.isEmpty, parentTitle != "之前的任务" {
                    return parentTitle
                }
                if let childTitle = child.title, !childTitle.isEmpty, !childTitle.hasPrefix("/") {
                    return childTitle
                }
                return String(localized: "后台任务")
            }()
            insert(id: child.workID ?? parent?.workID ?? child.originRunID ?? child.id,
                   title: resolvedTitle, phase: phase)
        }
        for task in tasks where task.isPending {
            if let runID = task.run?.runID, runs.contains(where: { $0.runID == runID }) { continue }
            let id = task.run?.workID ?? task.run?.runID ?? task.id.uuidString
            guard merged[id] == nil else { continue }
            let phase: Phase = task.deliveryFailed || task.needsReview || task.lastError != nil ? .attention
                : task.stopRequested || task.run?.cancelRequested == true ? .stopping
                : task.run?.pendingControls?.isEmpty == false || task.run?.waitReason == "computer_human" ? .waiting
                : task.run?.status == "running" ? .running
                : task.run == nil || task.run?.status == "queued" ? .queued : .attention
            insert(id: id, title: task.input, phase: phase)
        }
        items = merged.values.sorted { $0.phase == $1.phase ? $0.id < $1.id : $0.phase > $1.phase }
    }
}
