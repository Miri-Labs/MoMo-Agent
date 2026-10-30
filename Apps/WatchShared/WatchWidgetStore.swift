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
        Self.applyProtection(to: root)
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
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            #if os(iOS) || os(watchOS)
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            #else
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            #endif
        }
        Self.applyProtection(to: parent)
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        Self.applyProtection(to: url)
    }

    private static func applyProtection(to url: URL) {
        #if os(iOS) || os(watchOS)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
