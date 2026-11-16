import Foundation

/// Work that may block for a long time — a file call on a share that stopped answering waits for the SMB timeout, and nothing
/// interrupts it — run one at a time on ONE serial queue, the newest request per key replacing every older one that has not
/// started (stage 7 Task 14 review: the Settings counts). Typing a dead server's path then leaves at most one blocked thread,
/// not one per pause, and when it unblocks only the latest text is counted. Each request waits `delay` first (the Mac's 250 ms
/// debounce); no timer is left once the queue is empty.
final class LatestOnlyWork: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [String: DispatchWorkItem] = [:]

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Runs `work` after `delay` on the queue, unless a newer `submit` for `key` (or `cancel(key)`) comes before it starts.
    func submit(key: String, after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: work)
        lock.lock()
        pending[key]?.cancel()
        pending[key] = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drops `key`'s request that has not started (a running one finishes; its result is the caller's to ignore).
    func cancel(key: String) {
        lock.lock()
        pending[key]?.cancel()
        pending[key] = nil
        lock.unlock()
    }
}
