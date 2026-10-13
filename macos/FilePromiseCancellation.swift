import Foundation

/// Cancellation is registered before Finder can queue a promise. Serializing
/// it with launch also closes the gap between checking and starting a helper.
final class FilePromiseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CocoaError(.userCancelled) }
    }

    func run(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CocoaError(.userCancelled) }
        process = child
        try child.run()
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}
