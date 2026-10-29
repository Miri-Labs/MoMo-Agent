import Foundation
import os
import WidgetKit
import MoMoContracts

actor WatchWidgetPublisher {
    private let store: WatchWidgetStore
    private var latestRevision: UInt64?
    private let logger = Logger(subsystem: "com.momoagent.ios.watchkitapp", category: "Widget")

    init(store: WatchWidgetStore) { self.store = store }

    func publish(_ snapshot: WatchWidgetSnapshot) {
        guard latestRevision.map({ snapshot.revision > $0 }) ?? true else { return }
        latestRevision = snapshot.revision
        do {
            try store.write(snapshot)
            WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetStore.kind)
        } catch {
            // Widget storage must not stop microphone capture or alter the recording ledger.
            logger.error("Widget state write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
