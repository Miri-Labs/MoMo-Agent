import Foundation
import MoMoAgentClient
import MoMoContracts

/// The only translation between agent facts and the standalone renderer's wire format.
struct ChatRenderSnapshot: Encodable, Equatable {
    struct Focus: Encodable, Equatable {
        let requestID: String
        let messageID: String
    }
    var focus: Focus? = nil
    struct Message: Encodable, Equatable {
        struct Block: Encodable, Equatable {
            struct Tool: Encodable, Equatable {
                let id: String
                let name: String
                let input: String
                let output: String?
                let state: String
            }
            let id: String
            let type: String
            var text: String?
            var redacted: Bool?
            var tool: Tool?
            var name: String?
            var preview: String?
            var kind: String?
            var format: String?
            var size: String?
            var attachmentID: String?
        }
        let id: String
        let turnID: String
        let role: String
        let state: String
        let blocks: [Block]
        var delivery: String? = nil
        var deliveryError: String? = nil
    }
    let sessionID: String
    let locale: String
    let messages: [Message]
    let busy: Bool
    let stopped: Bool
    let canRegenerate: Bool
    let contextState: String
    var waitingForReply: Bool? = nil
    let readingPosition: ChatReadingPosition?

    // Match the Web renderer even when a system event follows the last outgoing message.
    var deliveryReceiptMessageID: String? {
        guard let index = messages.lastIndex(where: { $0.role == "user" }),
              let delivery = messages[index].delivery, ["delivered", "read"].contains(delivery),
              !messages.suffix(from: index + 1).contains(where: { $0.role == "assistant" }) else { return nil }
        return messages[index].id
    }

    @MainActor init(store: RemoteTaskStore, readingPosition: ChatReadingPosition? = nil, notificationTarget: AgentNotificationTarget? = nil) {
        if let target = notificationTarget, target.matches(store.connection), let messageID = target.messageID {
            focus = Focus(requestID: target.deliveryID.uuidString, messageID: messageID)
        }
        sessionID = store.connection.assistantID.uuidString
        locale = AppLanguage.current.rawValue
        busy = store.hasActiveTask
        stopped = false; contextState = "idle"; canRegenerate = false
        waitingForReply = store.waitingForReply
        self.readingPosition = readingPosition
        let confirmedOperations = Set(store.messages.compactMap(\.operationID))
        let confirmedRuns = Set(store.messages.compactMap(\.runID))
        func receipt(runID: String?, operationID: UUID?, messageState: String? = nil, serverConfirmed: Bool = false) -> String? {
            let local = store.tasks.first { $0.id == operationID || (runID != nil && $0.run?.runID == runID) }?.run
            let remote = store.sharedRuns.first { $0.runID == (runID ?? local?.runID) }
            return AgentMessageReceipt.resolve(runs: [local, remote].compactMap { $0 },
                messageState: messageState, serverConfirmed: serverConfirmed)?.rawValue
        }
        let timeline: [(Date, Message)] = store.tasks.filter { task in
            !confirmedOperations.contains(task.id) && !(task.run.map { confirmedRuns.contains($0.runID) } ?? false)
        }.flatMap { task -> [(Date, Message)] in
            let turn = task.id.uuidString
            var rows: [(Date, Message)] = []
            if task.backgroundMessageIDs == nil {
                var blocks: [Message.Block] = (task.attachments ?? []).map { item in
                    .init(id: turn + ":attachment:\(item.id.uuidString)", type: "attachment", name: item.name,
                        preview: item.preview.map { "data:image/jpeg;base64," + $0.base64EncodedString() }, kind: item.kind.rawValue,
                        format: item.displayFormat, size: item.displaySize, attachmentID: item.id.uuidString)
                }
                if !task.input.isEmpty || blocks.isEmpty {
                    blocks.append(.init(id: turn + ":input", type: "text", text: task.input))
                }
                rows.append((task.createdAt, Message(id: turn + ":user", turnID: turn, role: "user", state: "complete",
                blocks: blocks,
                delivery: task.deliveryFailed ? "failed" : receipt(runID: task.run?.runID, operationID: task.id), deliveryError: task.lastError)))
            }
            for (index, text) in (task.reply?.messages ?? []).enumerated() {
                let date = task.replyReceivedAt.flatMap { index < $0.count ? $0[index] : nil } ?? task.createdAt
                rows.append((date, Message(id: turn + ":reply-\(index)", turnID: turn, role: "assistant", state: "complete",
                    blocks: [.init(id: turn + ":reply-\(index)", type: "text", text: text)])))
            }
            if let text = task.run?.output, !text.isEmpty {
                rows.append((task.finishedAt ?? task.createdAt, Message(id: turn + ":assistant", turnID: turn, role: "assistant", state: "complete",
                    blocks: [.init(id: turn + ":output", type: "text", text: text)])))
            }
            if let run = task.run, run.isTerminal, run.status != "completed" {
                let text = run.status == "failed" ? String(localized: "这次没能完成。") + (run.error.map { "\n" + $0 } ?? "") : String(localized: "已停止。")
                rows.append((task.finishedAt ?? task.createdAt, Message(id: turn + ":status", turnID: turn + ":status", role: "system", state: "complete",
                    blocks: [.init(id: turn + ":status", type: "text", text: text)])))
            }
            return rows
        }
        let remoteRows = store.displayMessages.map { row in
            let outgoing = row.role == "user" ? row.operationID?.uuidString : nil
            let attachments = row.attachments ?? (row.operationID.flatMap { id in store.tasks.first(where: { $0.id == id })?.attachments }) ?? []
            var blocks: [Message.Block] = attachments.map { item in
                .init(id: row.id + ":attachment:\(item.id.uuidString)", type: "attachment", name: item.name,
                    preview: item.preview.map { "data:image/jpeg;base64," + $0.base64EncodedString() }, kind: item.kind.rawValue,
                    format: item.displayFormat, size: item.displaySize, attachmentID: item.id.uuidString)
            }
            if !row.content.isEmpty || blocks.isEmpty {
                blocks.append(.init(id: row.id + ":text", type: "text", text: row.content))
            }
            return Message(id: outgoing.map { $0 + ":user" } ?? row.id, turnID: outgoing ?? (row.role == "system" ? row.id : row.runID ?? row.id),
                role: row.role, state: "complete", blocks: blocks,
                delivery: row.role == "user" ? receipt(runID: row.runID, operationID: row.operationID,
                    messageState: row.deliveryState, serverConfirmed: true) : nil)
        }
        let localRows = timeline.enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.map { $0.element.1 }
        let outbox = Set(store.tasks.filter { $0.sessionID == store.conversation?.sessionID }.map { $0.id.uuidString })
        // Server sequence is authoritative even when a device or wall clock moves.
        messages = localRows.filter { !outbox.contains($0.turnID) } + remoteRows + localRows.filter { outbox.contains($0.turnID) }
        if messages.last(where: { $0.role == "user" })?.delivery != "read" { waitingForReply = false }
    }
    init(sessionID: UUID?, messages: [AgentChatMessage], busy: Bool, stopped: Bool = false,
         readingPosition: ChatReadingPosition? = nil, contextState: AgentContextState = .idle, canRegenerate: Bool = true) {
        self.sessionID = sessionID?.uuidString ?? "new"
        self.locale = AppLanguage.current.rawValue
        self.canRegenerate = canRegenerate
        self.busy = busy
        self.stopped = stopped
        self.contextState = stopped ? AgentContextState.idle.rawValue : contextState.rawValue
        self.readingPosition = readingPosition?.sessionID == sessionID ? readingPosition : nil
        self.messages = messages.map { message in
            Message(id: message.id, turnID: message.turnID, role: message.role, state: message.state.rawValue,
                blocks: message.blocks.map { block in
                    switch block.content {
                    case .text(let text): return .init(id: block.id, type: "text", text: text)
                    case .attachment(let item):
                        return .init(id: block.id, type: "attachment", name: item.name,
                            preview: item.preview.map { "data:image/jpeg;base64," + $0.base64EncodedString() }, kind: item.kind.rawValue,
                            format: item.displayFormat, size: item.displaySize, attachmentID: item.id.uuidString)
                    case .reasoning(let text, let redacted):
                        return .init(id: block.id, type: "reasoning", text: text, redacted: redacted)
                    case .tool(let tool):
                        return .init(id: block.id, type: "tool", tool: .init(id: tool.id, name: tool.name,
                            input: tool.input, output: tool.output, state: tool.state.rawValue))
                    }
                })
        }
    }
}
