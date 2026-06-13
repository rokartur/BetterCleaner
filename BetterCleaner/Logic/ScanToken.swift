import Foundation

/// A thread-safe cancellation flag for a background scan. The UI creates one per
/// scan and cancels the previous one when the user selects another app, so the
/// scanner can stop early instead of running every stale scan to completion (which
/// is what made clicking through the sidebar feel slow — the searches piled up).
///
/// `isCancelled` is read from the scan's worker thread while `cancel()` is called
/// from the main thread, so access is lock-guarded (a bare `Bool` read/write across
/// threads is a data race). The `NSLock` makes every access thread-safe, so the
/// type is safe to share across the concurrency boundary — `@unchecked Sendable`.
final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
