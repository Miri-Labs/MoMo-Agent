import Foundation
import MoMoContracts

/// An SDK callback may arrive after our deadline. Resume once and release its timer on completion.
typealias AudioBlockReplyGate = LinkReplyGate<AudioBlockReply>

final class LinkReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var deadline: Task<Void, Never>?
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let completed: Result<Value, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed); return false }
        return true
    }
    func startDeadline(after delay: Duration = .seconds(25), failure: any Error = AudioBlockTransferError.timedOut) {
        lock.withLock {
            guard continuation != nil else { return }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.finish(.failure(failure))
            }
        }
    }
    @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
        let saved: (Bool, CheckedContinuation<Value, any Error>?) = lock.withLock {
            guard self.result == nil else { return (false, nil) }
            self.result = result
            let saved = continuation; continuation = nil
            deadline?.cancel(); deadline = nil
            return (true, saved)
        }
        saved.1?.resume(with: result)
        return saved.0
    }
}
