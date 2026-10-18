import Foundation

/// Blocking storage calls must never occupy AppKit or Swift's cooperative
/// executor. Cancellation/timeout releases the caller even if the kernel is
/// still waiting for a disk; the bounded worker owns that call until it ends.
enum NativeFileWork {
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MyCloudDriver.storage-work"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private static let cleanupWorkers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MyCloudDriver.storage-cleanup"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private static let cancellationWorkers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MyCloudDriver.storage-cancellation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private static let descriptorWorkers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MyCloudDriver.storage-descriptor-close"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private static let memoryCleanup = DispatchQueue(label: "MyCloudDriver.preview-memory-release", qos: .utility)
    private static let admissionLock = NSLock()
    private static var outstanding = 0
    private static var asynchronousOutstanding = 0
    private static let maximumOutstanding = 64

    static func run<T>(timeout: TimeInterval = 30, priority: Operation.QueuePriority = .normal,
                       onCancel: @escaping @Sendable () -> Void = {},
                       _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let state = NativeFileWorkResult<T>(onCancel: onCancel)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !state.isFinished else { return }
                admissionLock.lock()
                let admitted = outstanding < maximumOutstanding
                if admitted { outstanding += 1 }
                admissionLock.unlock()
                guard admitted else {
                    state.finish(.failure(NativeFileWorkFailure.busy))
                    return
                }
                let work = BlockOperation {
                    guard !state.isFinished else { return }
                    state.finish(Result { try operation() })
                }
                work.queuePriority = priority
                work.completionBlock = {
                    admissionLock.lock(); outstanding -= 1; admissionLock.unlock()
                }
                state.bind(work)
                if timeout.isFinite, timeout > 0 {
                    let timer = DispatchWorkItem { state.cancel(with: NativeFileWorkFailure.timedOut) }
                    state.bind(timer)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                }
                workers.addOperation(work)
            }
        }, onCancel: { state.cancel(with: CancellationError()) })
    }

    /// Some File Providers ignore cancellation until their writer finishes.
    /// Do not use a task group to race a timeout: its scope would still wait for
    /// that child. The unstructured writer keeps its own directory lease, while
    /// this one-shot result releases the UI immediately on cancellation.
    static func asyncRun<T>(timeout: TimeInterval = 30,
                            _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let cancellation = NativeFileAsyncCancellation()
        let state = NativeFileWorkResult<T>(onCancel: { cancellation.cancel() })
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard !state.isFinished else { return }
                admissionLock.lock()
                let admitted = asynchronousOutstanding < 16
                if admitted { asynchronousOutstanding += 1 }
                admissionLock.unlock()
                guard admitted else { state.finish(.failure(NativeFileWorkFailure.busy)); return }
                let task = Task.detached(priority: .userInitiated) {
                    defer {
                        cancellation.clear()
                        endAsyncWork()
                    }
                    do {
                        guard !state.isFinished else { return }
                        try Task.checkCancellation()
                        state.finish(.success(try await operation()))
                    } catch { state.finish(.failure(error)) }
                }
                cancellation.bind(task)
                if timeout.isFinite, timeout > 0 {
                    let timer = DispatchWorkItem { state.cancel(with: NativeFileWorkFailure.timedOut) }
                    state.bind(timer)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                }
            }
        }, onCancel: { state.cancel(with: CancellationError()) })
    }

    private static func endAsyncWork() {
        admissionLock.lock(); asynchronousOutstanding -= 1; admissionLock.unlock()
    }

    /// Only pass directories owned by a completed/cancelled preparation. A
    /// provider that can still write must retain its lease until it has stopped.
    static func cleanup(_ directory: URL) {
        performCleanup { try? FileManager.default.removeItem(at: directory) }
    }

    static func performCleanup(_ operation: @escaping @Sendable () -> Void) {
        cleanupWorkers.addOperation(operation)
    }
    static func performCancellation(_ operation: @escaping @Sendable () -> Void) {
        cancellationWorkers.addOperation(operation)
    }
    static func performDescriptorCleanup(_ operation: @escaping @Sendable () -> Void) {
        descriptorWorkers.addOperation(operation)
    }
    static func performMemoryCleanup(_ operation: @escaping @Sendable () -> Void) {
        // A network close must never prevent old RAM mappings being freed.
        memoryCleanup.async(execute: operation)
    }
}

private final class NativeFileAsyncCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var completed = false
    func bind(_ task: Task<Void, Never>) {
        lock.lock()
        if !completed { self.task = task }
        let cancelled = cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func clear() { lock.lock(); task = nil; completed = true; lock.unlock() }
}

enum NativeFileWorkFailure: LocalizedError {
    case timedOut, busy
    var errorDescription: String? {
        switch self {
        case .timedOut: return "The disk or network share did not respond in time. Check its connection, then retry."
        case .busy: return "Storage is still busy with earlier requests. Wait a moment, then retry."
        }
    }
}

private final class NativeFileWorkResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var completed = false
    private weak var work: Operation?
    private var timer: DispatchWorkItem?
    private let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if completed {
            let result = self.result!; self.result = nil; lock.unlock()
            continuation.resume(with: result)
        } else { self.continuation = continuation; lock.unlock() }
    }
    func bind(_ work: Operation) {
        lock.lock(); self.work = work; let completed = completed; lock.unlock()
        if completed { work.cancel() }
    }
    func bind(_ timer: DispatchWorkItem) {
        lock.lock(); let completed = completed
        if !completed { self.timer = timer }
        lock.unlock()
        if completed { timer.cancel() }
    }
    @discardableResult
    func finish(_ result: Result<Value, Error>, cancelling: Bool = false) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        let continuation = continuation; self.continuation = nil
        if continuation == nil { self.result = result }
        let timer = timer; self.timer = nil
        let work = work
        lock.unlock()
        timer?.cancel()
        if cancelling { work?.cancel() }
        continuation?.resume(with: result)
        if cancelling { NativeFileWork.performCancellation(onCancel) }
        return true
    }
    func cancel(with error: Error) { finish(.failure(error), cancelling: true) }
}

/// A materializer may ignore task cancellation and finish writing later. Each
/// writer retains this lease, so asynchronous UI teardown never deletes its
/// staging directory while that writer can still use it.
final class NativePreviewDirectory: @unchecked Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
    deinit { NativeFileWork.cleanup(url) }
}
