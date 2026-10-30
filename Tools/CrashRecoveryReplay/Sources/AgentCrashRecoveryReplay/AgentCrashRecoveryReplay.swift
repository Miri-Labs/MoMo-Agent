#if !DEBUG || !os(macOS)
#error("AgentCrashRecoveryReplay requires Debug macOS observation hooks.")
#endif
import Darwin
import Foundation
import PiDurableKit
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(description: message) }
}
private func emit<T: Encodable>(_ value: T) throws {
    var data = try WireJSON.encode(value)
    data.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: data)
}
private func stop(_ boundary: String) -> Never {
    struct Event: Encodable { let event = "boundary"; let boundary: String; let processID: Int32 = getpid() }
    do { try emit(Event(boundary: boundary)) } catch { exit(70) }
    guard raise(SIGSTOP) == 0 else { exit(71) }
    exit(72) // Resuming instead of killing this process invalidates the experiment.
}

private let originalText = "OLD_AGENT_CRASH_SOURCE_7A2：周五下午三点讨论，负责人待确认。"
private let revisedText = "NEW_AGENT_CRASH_SOURCE_9B4：已改为周六下午四点，负责人仍待确认。"
private let userText = "整理这份资料并保存计划"
private let planTitle = "强杀验证原计划"
private let planBody = "原计划内容，负责人待确认。"

private struct Fixture: Codable {
    let receiverDeviceID: UUID
    let libraryInstanceID: UUID
    let transcript: TranscriptDocument
    let source: SourceReference
    let agentSessionID: UUID
    let requestID: UUID
    let contextClock: AgentContextClock
}

private struct Report: Codable {
    let phase: String
    var processID: Int32 = getpid()
    var providerCalls: Int = 0
    var oldSessionRejected = false
    var oldWriteRejected = false
    var oldSessionError: String?
    var oldWriteError: String?
    var completedCleanups: [UUID] = []
    var plans: [PlanDocument] = []
    var newSessionID: UUID?
    var newRequestID: UUID?
    var originalUserMessages: Int?
}

/// Observes the actual messages delivered by the real Pi harness to the scripted provider.
/// It never writes Archive or Pi state. These are synthetic fixture messages, not API traffic.
private actor ProviderProbe {
    let logURL: URL
    var calls = 0
    var planRequestID: UUID?
    var source: SourceReference?
    var title = planTitle
    var body = planBody
    var requiredMarker: String?
    var forbiddenMarker: String?

    init(root: URL, phase: String) { logURL = root.appendingPathComponent("\(phase).provider.jsonl") }
    func setPlan(requestID: UUID, source: SourceReference, title: String = planTitle, body: String = planBody) {
        planRequestID = requestID; self.source = source; self.title = title; self.body = body
    }
    func setText(required: String?, forbidden: String?) {
        planRequestID = nil; source = nil; requiredMarker = required; forbiddenMarker = forbidden
    }
    func count() -> Int { calls }
    func respond(_ messages: [Message]) throws -> FauxResponse {
        calls += 1
        try require(calls <= 12, "Unexpected provider loop")
        struct Request: Encodable { let sequence: Int; let messages: [Message] }
        var data = try WireJSON.encode(Request(sequence: calls, messages: messages)); data.append(0x0a)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try data.write(to: logURL, options: .withoutOverwriting)
        } else {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        }
        // Pi system sections are separate from SystemMessage.text. Inspect the actual complete envelope.
        let combined = String(decoding: try WireJSON.encode(messages), as: UTF8.self)
        if let requiredMarker { try require(combined.contains(requiredMarker), "Current source missing from actual provider messages") }
        if let forbiddenMarker { try require(!combined.contains(forbiddenMarker), "Invalidated source reached the provider") }
        guard let requestID = planRequestID, let source else { return .text("当前有效资料已核对。") }
        let committed = messages.contains { message in
            guard case .toolResult(let result) = message, result.toolName == "write_plan", !result.isError,
                  let plan = try? WireJSON.decode(PlanDocument.self, from: Data(result.text.utf8)) else { return false }
            return plan.operationID == requestID
        }
        if committed { return .text("原计划已保存。") }
        return FauxResponse(.toolCall("write_plan", ["title": .string(title), "body": .string(body),
            "sources": .array([try JSONValue(encoding: source)])]))
    }
}

@main private enum AgentCrashRecoveryReplay {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            try require(arguments.count == 3, "Usage: AgentCrashRecoveryReplay PHASE NEW_CASE_DIRECTORY CASE")
            let phase = arguments[0], root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            let boundary = arguments[2]
            try require(boundary.hasPrefix("J20-") || boundary.hasPrefix("J21-") || boundary.hasPrefix("J23-"), "Unknown case")
            try require(!boundary.hasPrefix("J20-"), "J20 plan cases were retired; use J21/J23 history cleanup cases")
            if phase == "prepare" { try await prepare(root: root, boundary: boundary); return }
            let fixture = try WireJSON.decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: fixture.receiverDeviceID)
            try require(archive.libraryInstanceID == fixture.libraryInstanceID, "Library identity changed")
            let probe = ProviderProbe(root: root, phase: phase)
            let host = try await host(root: root, archive: archive, clock: fixture.contextClock, probe: probe)
            switch phase {
            case "receive": try await interrupt(root: root, boundary: boundary, fixture: fixture, archive: archive, host: host, probe: probe)
            case "recover":
                if boundary.hasPrefix("J20-") { try await recoverPlan(root: root, fixture: fixture, archive: archive, host: host, probe: probe) }
                else { try await recoverCleanup(root: root, boundary: boundary, fixture: fixture, archive: archive, host: host, probe: probe) }
            case "verify": try await verify(root: root, boundary: boundary, fixture: fixture, archive: archive, host: host, probe: probe)
            default: throw Failure(description: "Unknown phase")
            }
            try await host.close()
        } catch {
            do { try emit(["event": "failure", "message": String(describing: error)]) } catch { print("Cannot emit failure") }
            exit(1)
        }
    }

    private static func host(root: URL, archive: ArchiveStore, clock: AgentContextClock, probe: ProviderProbe) async throws -> PiAgentHost {
        let configuration = try AgentProviderConfiguration(baseURL: URL(string: "https://fixture.invalid/v1")!, modelID: "scripted")
        let models = Models(credentials: .inMemory, builtinProviders: false)
        let faux = FauxProvider(id: ProviderAccess.providerID(configuration), models: [.init(id: "scripted")])
        try await models.register(faux)
        try await faux.respond { messages, _ in try await probe.respond(messages) }
        return try PiAgentHost(storageURL: root.appendingPathComponent("agent"), archive: archive,
            provider: ProviderAccess(models: models, configuration: configuration), contextClock: { clock })
    }

    private static func prepare(root: URL, boundary: String) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.json").path), "Fixture exists")
        let receiverID = UUID(), now = Date(timeIntervalSince1970: 1_792_022_400)
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: receiverID)
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "agent-crash-replay", sourceKind: .fixture,
            targetFrames: 160, wallClockAnchor: now.addingTimeInterval(-60), timezoneOffset: 28_800)
        guard let chunk = try writer.append(Array(repeating: 1, count: 160)).first else { throw Failure(description: "No fixture chunk") }
        let item = try archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
        _ = try await archive.commitReceivedChunk(item)
        guard let ticket = try await archive.claimAnalysisJob(configurationHash: "synthetic-text-no-asr") else { throw Failure(description: "No analysis job") }
        let span = TranscriptSpan(chunkID: chunk.envelope.manifest.chunkID, frames: chunk.envelope.manifest.frames, text: originalText)
        let transcript = try await archive.commitTranscript(ticket: ticket, spans: [span])
        try await archive.projectPendingDocuments()
        let clock = AgentContextClock(now: now, timezone: "Asia/Shanghai")
        let probe = ProviderProbe(root: root, phase: "prepare")
        let host = try await host(root: root, archive: archive, clock: clock, probe: probe)
        let fixture = Fixture(receiverDeviceID: receiverID, libraryInstanceID: archive.libraryInstanceID,
            transcript: transcript, source: transcript.source(for: span), agentSessionID: try await host.createSession(),
            requestID: UUID(), contextClock: clock)
        if !boundary.hasPrefix("J20-") {
            _ = try await archive.savePlan(operationID: fixture.requestID, title: planTitle, body: planBody, sources: [fixture.source])
            _ = try await host.submit(text: userText, sessionID: fixture.agentSessionID, requestID: fixture.requestID, selectedSource: fixture.source)
            try require(try await archive.plans().count == 1, "Legacy archive fixture was not preserved")
        }
        try await host.close()
        try WireJSON.encode(fixture).write(to: root.appendingPathComponent("fixture.json"), options: .withoutOverwriting)
        var report = Report(phase: "prepare"); report.providerCalls = await probe.count(); report.plans = try await archive.plans()
        try emit(report)
    }

    private static func interrupt(root: URL, boundary: String, fixture: Fixture, archive: ArchiveStore,
                                  host: PiAgentHost, probe: ProviderProbe) async throws {
        if boundary.hasPrefix("J20-") {
            await probe.setPlan(requestID: fixture.requestID, source: fixture.source)
            await archive.setPlanBoundaryObserver { if $0.rawValue == boundary { stop(boundary) } }
            await host.setPersistenceBoundaryObserver { if $0.rawValue == boundary { stop(boundary) } }
            _ = try await host.submit(text: userText, sessionID: fixture.agentSessionID, requestID: fixture.requestID, selectedSource: fixture.source)
        } else {
            // Open the real previous harness before invalidation, so the close boundary is exercised too.
            _ = try await host.snapshot(sessionID: fixture.agentSessionID)
            if boundary.hasPrefix("J21-") { _ = try await archive.deleteSession(id: fixture.source.sessionID) }
            else {
                let old = fixture.transcript.spans[0]
                _ = try await archive.reviseTranscript(sessionID: fixture.source.sessionID, expectedVersion: fixture.transcript.version,
                    spans: [TranscriptSpan(id: old.id, chunkID: old.chunkID, frames: old.frames, text: revisedText)])
            }
            if boundary.hasSuffix("invalidated") { stop(boundary) }
            await host.setPersistenceBoundaryObserver { observed in
                if boundary.hasSuffix("closed"), observed == .cleanupBeforeDirectoryRemoval { stop(boundary) }
                if boundary.hasSuffix("removed"), observed == .cleanupBeforeCompletion { stop(boundary) }
            }
            _ = try await host.cleanupInvalidatedSessions()
        }
        throw Failure(description: "Target boundary was not reached")
    }

    private static func recoverPlan(root: URL, fixture: Fixture, archive: ArchiveStore, host: PiAgentHost, probe: ProviderProbe) async throws {
        await probe.setPlan(requestID: fixture.requestID, source: fixture.source)
        let restored = try await host.snapshot(sessionID: fixture.agentSessionID)
        try require(restored.retryableRequest?.id == fixture.requestID, "Original logical request is not recoverable")
        _ = try await host.retry(sessionID: fixture.agentSessionID, requestID: fixture.requestID)
        guard let first = try await archive.plan(operationID: fixture.requestID) else { throw Failure(description: "Original plan missing after retry") }
        try require(first.title == planTitle && first.body == planBody && first.sources == [fixture.source], "Recovered plan changed")
        let beforeDuplicate = await probe.count()
        _ = try await host.submit(text: userText, sessionID: fixture.agentSessionID, requestID: fixture.requestID, selectedSource: fixture.source)
        try require(await probe.count() == beforeDuplicate, "Duplicate admission called the provider")
        try require(try await archive.plans().count == 1, "Original request created duplicate plans")
        // Harness.resume replays the pending real tool; duplicate admission checks its durable answer.
        let secondRequest = UUID()
        await probe.setPlan(requestID: secondRequest, source: fixture.source, title: "明确的新任务", body: "第二份独立计划")
        _ = try await host.submit(text: userText, sessionID: fixture.agentSessionID, requestID: secondRequest, selectedSource: fixture.source)
        let plans = try await archive.plans()
        try require(plans.count == 2 && plans.contains { $0.operationID == secondRequest && $0.id != first.id }, "New request was deduplicated incorrectly")
        let snapshot = try await host.snapshot(sessionID: fixture.agentSessionID)
        let users = snapshot.messages.filter { $0.role == "user" && $0.text == userText }.count
        try require(users == 2, "Restart duplicated the first user turn")
        var report = Report(phase: "recover"); report.providerCalls = await probe.count(); report.plans = plans
        report.newRequestID = secondRequest; report.originalUserMessages = users
        try emit(report)
    }

    private static func rejectOld(root: URL, fixture: Fixture, archive: ArchiveStore, host: PiAgentHost,
                                  probe: ProviderProbe, deletion: Bool, allowRemovedHistory: Bool = false) async throws -> (String, String) {
        var sessionError: String?, writeError: String?
        do { _ = try await host.submit(text: userText, sessionID: fixture.agentSessionID, requestID: fixture.requestID, selectedSource: fixture.source) }
        catch AgentError.sessionInvalidated { sessionError = "sessionInvalidated" }
        catch let error as CocoaError where allowRemovedHistory && error.code == .fileReadNoSuchFile {
            // A fresh host after completed cleanup has no metadata to open. Other IO errors are failures.
            let directory = root.appendingPathComponent("agent/\(fixture.agentSessionID.uuidString)")
            try require(!FileManager.default.fileExists(atPath: directory.path), "Missing metadata inside a surviving old session")
            sessionError = "historyMissingAfterCleanup"
        }
        do { _ = try await archive.savePlan(operationID: fixture.requestID, title: planTitle, body: planBody, sources: [fixture.source]) }
        catch ArchiveError.sessionDeleted(let id) where deletion && id == fixture.source.sessionID { writeError = "sessionDeleted" }
        catch ArchiveError.staleSource where !deletion { writeError = "staleSource" }
        let calls = await probe.count()
        guard let sessionError, let writeError, calls == 0 else { throw Failure(description: "Invalidated request resumed or wrote old content") }
        return (sessionError, writeError)
    }

    private static func recoverCleanup(root: URL, boundary: String, fixture: Fixture, archive: ArchiveStore,
                                       host: PiAgentHost, probe: ProviderProbe) async throws {
        try require(try await archive.pendingAgentCleanups() == [fixture.agentSessionID], "Crash lost pending cleanup")
        let rejected = try await rejectOld(root: root, fixture: fixture, archive: archive, host: host, probe: probe, deletion: boundary.hasPrefix("J21-"))
        let completed = try await host.cleanupInvalidatedSessions()
        let pending = try await archive.pendingAgentCleanups()
        try require(completed == [fixture.agentSessionID] && pending.isEmpty, "Normal cleanup did not complete")
        try await archive.projectPendingDocuments()
        try require(try await archive.plans().isEmpty, "Invalidated plan became visible")
        // A retired ID remains unusable after cleanup. A new session must read only valid current content.
        _ = try await rejectOld(root: root, fixture: fixture, archive: archive, host: host, probe: probe, deletion: boundary.hasPrefix("J21-"))
        let newSession = try await host.createSession()
        let isRevision = boundary.hasPrefix("J23-")
        await probe.setText(required: isRevision ? revisedText : nil, forbidden: originalText)
        _ = try await host.submit(text: "核对当前资料", sessionID: newSession)
        try require(await probe.count() == 1, "New session did not execute exactly one scripted request")
        var report = Report(phase: "recover"); report.providerCalls = await probe.count(); report.completedCleanups = completed
        report.oldSessionRejected = true; report.oldWriteRejected = true; report.newSessionID = newSession
        report.oldSessionError = rejected.0; report.oldWriteError = rejected.1
        try emit(report)
    }

    private static func verify(root: URL, boundary: String, fixture: Fixture, archive: ArchiveStore,
                               host: PiAgentHost, probe: ProviderProbe) async throws {
        let previous = try WireJSON.decode(Report.self, from: Data(contentsOf: root.appendingPathComponent("recover.json")))
        var report = Report(phase: "verify")
        if boundary.hasPrefix("J20-") {
            guard let original = try await archive.plan(operationID: fixture.requestID) else { throw Failure(description: "Plan disappeared on second restart") }
            try require(previous.plans.contains { $0.id == original.id && $0.operationID == original.operationID && $0.body == original.body && $0.sources == original.sources }, "Original plan identity changed on second restart")
            // Once a later request exists, the original request is rejected rather than re-admitted.
            var oldAdmissionRejected = false
            do { _ = try await host.submit(text: userText, sessionID: fixture.agentSessionID, requestID: fixture.requestID, selectedSource: fixture.source) }
            catch AgentError.invalidInput { oldAdmissionRejected = true }
            try require(oldAdmissionRejected, "An earlier request was re-admitted after a newer task")
            let plans = try await archive.plans()
            let unchanged = try WireJSON.encode(plans) == WireJSON.encode(previous.plans)
            try require(plans.count == 2 && unchanged, "Plans changed on second restart")
            report.oldSessionRejected = oldAdmissionRejected
        } else {
            let rejected = try await rejectOld(root: root, fixture: fixture, archive: archive, host: host, probe: probe,
                deletion: boundary.hasPrefix("J21-"), allowRemovedHistory: true)
            report.oldSessionRejected = true; report.oldWriteRejected = true
            report.oldSessionError = rejected.0; report.oldWriteError = rejected.1
            report.completedCleanups = try await host.cleanupInvalidatedSessions()
            try require(report.completedCleanups.isEmpty, "Cleanup was not durably completed")
            guard let newSession = previous.newSessionID else { throw Failure(description: "No new session identity") }
            let snapshot = try await host.snapshot(sessionID: newSession)
            try require(snapshot.messages.contains { $0.role == "assistant" && $0.text == "当前有效资料已核对。" }, "New valid history missing")
            report.newSessionID = newSession
        }
        report.plans = try await archive.plans(); report.providerCalls = await probe.count()
        try require(report.providerCalls == 0, "Read-only reopening invoked the provider")
        try emit(report)
    }
}
