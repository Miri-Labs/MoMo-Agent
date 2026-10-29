import Foundation
import MoMoContracts

struct WatchWidgetStore: Sendable {
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "MoMoWatchAppGroup") as? String ?? "group.com.momoagent.watch"
    static let kind = Bundle.main.object(forInfoDictionaryKey: "MoMoWatchWidgetKind") as? String ?? "com.momoagent.watch.capture"
    static let urlScheme = Bundle.main.object(forInfoDictionaryKey: "MoMoWatchURLScheme") as? String ?? "momoagent"
    let url: URL

    static func shared() throws -> Self {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw WatchWidgetError.sharedContainerUnavailable
        }
        return Self(url: root.appendingPathComponent("capture-widget.json"))
    }

    func read() throws -> WatchWidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(WatchWidgetSnapshot.self, from: Data(contentsOf: url))
        try snapshot.validate()
        return snapshot
    }

    func write(_ snapshot: WatchWidgetSnapshot) throws {
        try snapshot.validate()
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
