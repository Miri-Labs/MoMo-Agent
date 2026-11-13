import Foundation
import OSLog
import MoMoAgentClient

/// Bounded, local timing evidence. Never stores addresses, credentials or message content.
final class TailnetDiagnostics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.momoagent.tailnet-diagnostics", qos: .utility)
    private let file: URL
    private var target: String?
    private var routes: [[String: Any]] = []
    private var requests: [[String: Any]] = []
    private var chat: [[String: Any]] = []
    private var needsRestore = true
    private var link: [[String: Any]] = []
    private var latest: [String: [String: Any]] = [:]
    private var lastFailure: [String: Any]?
    private var scheduled = false

    init(directory: URL) {
        file = directory.appendingPathComponent("network-timing.json")
        queue.async { self.restore() }
    }

    private func restore() {
        guard needsRestore else { return }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { needsRestore = false; return }
        catch { return } // The previous history may still be protected before the first unlock.
        needsRestore = false
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger(subsystem: "app.momoagent", category: "network").error("Cannot decode previous network diagnostics")
            return
        }
        routes = Array(((saved["routes"] as? [[String: Any]] ?? []) + routes).suffix(48))
        link = Array(((saved["link"] as? [[String: Any]] ?? []) + link).suffix(160))
        requests = Array(((saved["requests"] as? [[String: Any]] ?? []) + requests).suffix(96))
        chat = Array(((saved["chat"] as? [[String: Any]] ?? []) + chat).suffix(128))
    }

    // Only caller-owned stage names, outcomes and allowlisted fields belong here.
    func recordLink(_ stage: String, _ outcome: String, details: [String: String] = [:], error: Error? = nil) {
        let causes = error.map(Self.causes)
        let at = Date().timeIntervalSince1970
        queue.async {
            var entry: [String: Any] = ["stage": stage, "outcome": outcome]
            if !details.isEmpty { entry["details"] = details }
            entry["causes"] = causes
            if var previous = self.latest[stage] {
                previous.removeValue(forKey: "at")
                if NSDictionary(dictionary: previous).isEqual(to: entry) { return }
            }
            entry["at"] = at
            self.latest[stage] = entry
            self.link.append(entry)
            self.link = Array(self.link.suffix(160))
            self.scheduleWrite()
        }
    }

    // CFNetwork often wraps a POSIX or CFStream failure in a generic URL error.
    private static func causes(_ error: Error) -> [[String: String]] {
        var result: [[String: String]] = []
        var current: NSError? = error as NSError
        let domains = [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain,
                       NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork", "kCFErrorDomainNetwork"]
        while let item = current, result.count < 5 {
            var row = ["domain": domains.contains(item.domain) ? item.domain : "other", "code": String(item.code)]
            for key in ["_kCFStreamErrorDomainKey", "_kCFStreamErrorCodeKey"] {
                if let value = item.userInfo[key] as? NSNumber { row[key] = value.stringValue }
            }
            result.append(row)
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    func recordChat(_ operation: StaticString, state: RemoteTaskStore.ConnectionState, error: Error?, retryAt: Date?) {
        queue.sync {
            // A confirmed response closes an incident, including one from a previous app launch.
            if error == nil, !needsRestore, chat.last?["error"] == nil { return }
            var entry: [String: Any] = ["at": Date().timeIntervalSince1970, "operation": operation.description,
                                        "state": state.rawValue]
            if let error {
                let nsError = error as NSError
                if case AgentClientError.http(let status, _, _, _) = error {
                    entry["error"] = "HTTP"; entry["code"] = status
                } else {
                    entry["error"] = String(reflecting: type(of: error))
                    entry["code"] = nsError.code
                    entry["causes"] = Self.causes(error)
                    if [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, "kCFErrorDomainCFNetwork"].contains(nsError.domain) {
                        entry["domain"] = nsError.domain
                    }
                }
            }
            // Keep the onset even if the request/route rings wrap during a long outage.
            var evidence: [String: Any] = ["link": latest]
            evidence["route"] = routes.last
            evidence["lastRequestFailure"] = lastFailure
            entry["evidence"] = evidence
            entry["retryAt"] = retryAt?.timeIntervalSince1970
            if let last = chat.last, error != nil,
               last["state"] as? String == state.rawValue, last["operation"] as? String == operation.description,
               last["error"] as? String == entry["error"] as? String, last["code"] as? Int == entry["code"] as? Int,
               last["domain"] as? String == entry["domain"] as? String {
                entry["lastAt"] = entry["at"]
                entry["lastEvidence"] = entry["evidence"]
                entry["evidence"] = last["evidence"]
                entry["at"] = last["at"]
                entry["count"] = (last["count"] as? Int ?? 1) + 1
                chat.removeLast()
            }
            chat.append(entry)
            chat = Array(chat.suffix(128))
            write()
        }
    }

    func observePeer(_ host: String?) { queue.async { self.target = host } }

    func recordStatus(_ data: Data) {
        queue.async {
            guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let summary = Self.routeSummary(status, target: self.target)
            let states = ["Running", "NeedsLogin", "NeedsMachineAuth", "Starting", "Stopped", "NoState", "InUseOtherUser"]
            let state = status["BackendState"] as? String ?? ""
            let health = (status["Health"] as? [String] ?? []).map { warning -> String in
                let text = warning.lowercased()
                if text.contains("coordination server") { return "coordination-server" }
                if text.contains("relay") || text.contains("derp") { return "relay" }
                if text.contains("logged out") { return "logged-out" }
                return "other"
            }
            var observation: [String: Any] = ["backend": states.contains(state) ? state : "unknown",
                "scope": self.target == nil ? "activePeers" : "pairedPeer", "peers": summary,
                "health": Array(Set(health)).sorted()]
            if var previous = self.routes.last {
                previous.removeValue(forKey: "at")
                if NSDictionary(dictionary: previous).isEqual(to: observation) { return }
            }
            observation["at"] = Date().timeIntervalSince1970
            self.routes.append(observation)
            self.routes = Array(self.routes.suffix(48))
            self.scheduleWrite()
        }
    }

    static func routeSummary(_ status: [String: Any], target: String?) -> [[String: String]] {
        let peers = (status["Peer"] as? [String: [String: Any]] ?? [:]).values
        return peers.compactMap { peer -> [String: String]? in
            if let target {
                guard (peer["TailscaleIPs"] as? [String] ?? []).contains(target) else { return nil }
            } else if peer["Active"] as? Bool != true { return nil }
            let active = peer["Active"] as? Bool == true
            let direct = peer["CurAddr"] as? String ?? ""
            let relay = peer["PeerRelay"] as? String ?? ""
            let derp = peer["Relay"] as? String ?? ""
            // Relay is the peer's home DERP even when traffic is direct. Match status CLI precedence.
            let route = !active ? "idle" : !direct.isEmpty ? "direct" : !relay.isEmpty ? "peer-relay" : !derp.isEmpty ? "derp" : "unknown"
            var summary = ["route": route, "online": peer["Online"] as? Bool == true ? "yes" : "no"]
            if let mapped = peer["InNetworkMap"] as? Bool { summary["mapped"] = mapped ? "yes" : "no" }
            return summary
        }.sorted { lhs, rhs in
            let keys = ["route", "online", "mapped"]
            return keys.map { lhs[$0] ?? "" }.lexicographicallyPrecedes(keys.map { rhs[$0] ?? "" })
        }
    }

    static func category(_ url: URL?) -> String? {
        guard let path = url?.path else { return nil }
        switch path {
        case "/momo/v1/conversation/messages": return "messages"
        case "/momo/v1/conversation/works": return "work-overview"
        case "/momo/v1/conversation/runs": return "runs"
        case "/momo/v1/conversation/read": return "read"
        case "/momo/v1/conversation/subscribe": return "conversation-events"
        case "/momo/v1/conversation/snapshot": return "conversation-snapshot"
        case "/momo/v1/conversation": return "conversation"
        case "/v1/capabilities": return "capabilities"
        case "/pair/identity": return "identity"
        default:
            if path.hasPrefix("/desktop/") {
                return ["frame", "frames", "status"].contains(url?.lastPathComponent ?? "") ? "desktop-" + (url?.lastPathComponent ?? "") : "desktop-control"
            }
            if path.hasPrefix("/pair/requests") { return "pairing" }
            if path.hasPrefix("/v1/runs/"), path.hasSuffix("/events") { return "events" }
            return nil
        }
    }

    func recordVideo(_ stage: String, statistics: [String: String] = [:]) {
        // Counters only: no pixels, SDP, network addresses or input contents.
        queue.async {
            self.requests.append(["at": Date().timeIntervalSince1970, "category": "desktop-video",
                                  "event": stage, "statistics": statistics])
            self.requests = Array(self.requests.suffix(96)); self.scheduleWrite()
        }
    }

    static let attemptHeader = "X-MoMo-Connection-Attempt"

    func recordAttempt(_ request: URLRequest, event: String, http: Int? = nil) {
        guard let category = Self.category(request.url),
              let attempt = request.value(forHTTPHeaderField: Self.attemptHeader) else { return }
        let at = Date().timeIntervalSince1970
        queue.async {
            var entry: [String: Any] = ["at": at, "category": category, "attempt": attempt, "event": event]
            entry["status"] = http
            self.requests.append(entry)
            self.requests = Array(self.requests.suffix(96))
            self.scheduleWrite()
        }
    }

    func recordFailure(_ error: Error, request: URLRequest?, stage: String = "request") {
        guard let category = Self.category(request?.url) else { return }
        let causes = Self.causes(error)
        let code = (error as NSError).code
        let attempt = request?.value(forHTTPHeaderField: Self.attemptHeader)
        queue.async {
            var entry: [String: Any] = ["at": Date().timeIntervalSince1970, "category": category,
                "event": "failure", "stage": stage, "errorDomain": causes[0]["domain"]!, "errorCode": code, "causes": causes]
            entry["attempt"] = attempt
            self.lastFailure = entry
            self.requests.append(entry)
            self.requests = Array(self.requests.suffix(96))
            self.scheduleWrite()
        }
    }

    func record(_ metrics: URLSessionTaskMetrics, request: URLRequest?) {
        guard let category = Self.category(request?.url) else { return }
        func elapsed(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start) * 1_000)
        }
        let transactions: [[String: Any]] = metrics.transactionMetrics.map { transaction in
            var values: [String: Any] = [
                "reused": transaction.isReusedConnection, "proxy": transaction.isProxyConnection,
                "protocol": transaction.networkProtocolName ?? "unknown"
            ]
            values["fetchStartMs"] = elapsed(metrics.taskInterval.start, transaction.fetchStartDate)
            values["connectMs"] = elapsed(transaction.connectStartDate, transaction.connectEndDate)
            values["requestStartMs"] = elapsed(metrics.taskInterval.start, transaction.requestStartDate)
            values["requestSendMs"] = elapsed(transaction.requestStartDate, transaction.requestEndDate)
            values["responseWaitMs"] = elapsed(transaction.requestEndDate, transaction.responseStartDate)
            values["headersMs"] = elapsed(metrics.taskInterval.start, transaction.responseStartDate)
            values["bodyMs"] = elapsed(transaction.responseStartDate, transaction.responseEndDate)
            values["bodyBytes"] = transaction.countOfResponseBodyBytesReceived
            values["status"] = (transaction.response as? HTTPURLResponse)?.statusCode
            return values
        }
        // Encode before crossing the queue; Foundation's heterogeneous dictionary is not Sendable.
        var sample: [String: Any] = [
            "at": metrics.taskInterval.start.timeIntervalSince1970,
            "category": category, "method": request?.httpMethod == "POST" ? "POST" : "GET",
            "totalMs": metrics.taskInterval.duration * 1_000, "transactions": transactions
        ]
        sample["attempt"] = request?.value(forHTTPHeaderField: Self.attemptHeader)
        guard let data = try? JSONSerialization.data(withJSONObject: sample) else { return }
        queue.async {
            guard let sample = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.requests.append(sample); self.requests = Array(self.requests.suffix(96))
            self.scheduleWrite()
        }
    }

    private func scheduleWrite() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 5) {
            self.scheduled = false
            self.write()
        }
    }

    private func write() {
        restore()
        guard !needsRestore else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 3, "updatedAt": Date().timeIntervalSince1970,
                "routes": routes, "requests": requests, "chat": chat, "link": link
            ], options: [.sortedKeys])
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Logger(subsystem: "app.momoagent", category: "network").error("Cannot save network diagnostics: \(error as NSError, privacy: .private)")
        }
    }
}
