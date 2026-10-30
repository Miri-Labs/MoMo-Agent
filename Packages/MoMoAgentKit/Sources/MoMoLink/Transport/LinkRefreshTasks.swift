/// Removes ownership before invoking a completion, including reentrant or late expiration callbacks.
@MainActor
public final class LinkRefreshTasks<ID: Hashable> {
    private var completions: [ID: () -> Void] = [:]
    public init() {}
    public var isEmpty: Bool { completions.isEmpty }
    public func contains(_ id: ID) -> Bool { completions[id] != nil }

    public func insert(_ id: ID, completion: @escaping () -> Void) {
        guard completions[id] == nil else { return }
        completions[id] = completion
    }

    public func complete(_ id: ID) {
        guard let completion = completions.removeValue(forKey: id) else { return }
        completion()
    }

    public func completeAll() {
        let pending = Array(completions.values)
        completions.removeAll()
        for completion in pending { completion() }
    }
}
