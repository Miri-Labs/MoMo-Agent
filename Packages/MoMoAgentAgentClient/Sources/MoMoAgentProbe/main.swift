import Foundation
import MoMoAgentClient

@main
struct AgentProbe {
    struct Connection: Decodable {
        let base_url: URL
        let assistant_id: UUID
    }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            throw UsageError()
        }
        let data = URL(filePath: args[1], directoryHint: .isDirectory)
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: data.appending(path: "connection.json")))
        let credential = try String(contentsOf: data.appending(path: "api-key"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try AgentClient(baseURL: connection.base_url, credential: credential, assistantID: connection.assistant_id)
        switch args[0] {
        case "capabilities":
            try emit(await client.capabilities())
        case "submit":
            guard args.count == 5, let operationID = UUID(uuidString: args[3]) else { throw UsageError() }
            try emit(await client.submit(input: args[4], sessionID: args[2], operationID: operationID))
        case "status":
            guard args.count == 3 else { throw UsageError() }
            try emit(await client.run(id: args[2]))
        case "stop":
            guard args.count == 3 else { throw UsageError() }
            try await client.requestStop(runID: args[2])
            print("{\"stop_requested\":true}")
        case "conversation-smoke":
            try await conversationSmoke(data: data, client: client)
        default:
            throw UsageError()
        }
    }

    @MainActor
    static func conversationSmoke(data: URL, client: AgentClient) async throws {
        let connection = try JSONDecoder().decode(AgentConnection.self, from: Data(contentsOf: data.appending(path: "connection.json")))
        let file = data.appending(path: "runtime/im-journal.json")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw UsageError() }
        let store = try RemoteTaskStore(file: file, connection: connection, client: client)
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(90)
            while !condition() {
                guard Date() < deadline else {
                    throw NSError(domain: "ConversationSmoke", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Conversation timed out: \(store.failure ?? store.tasks.last?.run?.error ?? store.tasks.last?.lastError ?? "no receipt")"])
                }
                await store.refresh()
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        store.setDraft("MOMO_TEST_START_BACKGROUND"); try store.enqueue()
        try await wait { store.tasks.first?.isFinished == true }
        let started = data.appending(path: "workspace/im-worker-started")
        try await wait { FileManager.default.fileExists(atPath: started.path) }
        store.setDraft("我周五去上海"); try store.enqueue()
        try await wait { store.tasks.count >= 2 && store.tasks[1].isFinished }
        guard store.tasks[1].run?.output?.contains("周五去上海") == true,
              !FileManager.default.fileExists(atPath: data.appending(path: "workspace/im-worker-finished").path) else {
            throw NSError(domain: "ConversationSmoke", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A background tool blocked the information-only reply"])
        }
        try Data().write(to: data.appending(path: "workspace/im-worker-release"))
        try await wait { store.messages.contains { $0.content == "后台任务完成：MOMO_BACKGROUND_DONE" } }
        guard store.tasks.count == 2 else {
            throw NSError(domain: "ConversationSmoke", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Native completion did not return to the conversation"])
        }
        let count = store.tasks.count
        let reopened = try RemoteTaskStore(file: file, connection: connection, client: client)
        await reopened.refresh(); await reopened.refresh()
        guard reopened.tasks.count == count else {
            throw NSError(domain: "ConversationSmoke", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Reopening duplicated a completion wake"])
        }
        print("{\"chat_during_tool\":true,\"native_background_reply\":true,\"reopen_deduplicated\":true}")
    }

    static func emit(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    struct UsageError: LocalizedError {
        var errorDescription: String? {
            "Usage: momo-agent-probe capabilities DATA_DIR | submit DATA_DIR SESSION_ID OPERATION_UUID INPUT | status/stop DATA_DIR RUN_ID"
        }
    }
}
