import Darwin
import Foundation

/// One byte ledger for media previews, including other windows, the previous
/// selection's grace period and the next file. Decoder/AVPlayer memory is separate.
final class PreviewMemoryBudget: @unchecked Sendable {
    static let preferenceKey = DownloadBufferPolicy.preferenceKey
    static let shared = PreviewMemoryBudget()
    private let lock = NSLock()
    private var limit: Int64
    private var used: Int64 = 0
    private var pressure: UInt32 = 1
    private struct CacheOwner {
        let purge: @Sendable () -> Void
        let reclaim: @Sendable () -> Void
        let residentBytes: @Sendable () -> Int64
        var priority = 1
        var protectedUntil: TimeInterval = 0
    }
    private var cleanups: [UUID: CacheOwner] = [:]
    private var readAheadBlockedUntil: TimeInterval = 0
    private var lastRoomRequest: TimeInterval = 0
    private var pressureSource: DispatchSourceMemoryPressure?

    static func maximumMiB(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        DownloadBufferPolicy.maximumMiB(memory: physicalMemory)
    }
    static func clampedCapMiB(_ value: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        DownloadBufferPolicy.clampedCapMiB(value, memory: physicalMemory)
    }
    static func budgetBytes(capMiB: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64 {
        capMiB <= 0 ? MemoryRangeBuffer.automaticBudget(physicalMemory: physicalMemory)
            : Int64(clampedCapMiB(capMiB, physicalMemory: physicalMemory)) * (1 << 20)
    }

    init(limitBytes: Int64? = nil, monitorsPressure: Bool = true) {
        limit = max(1, limitBytes ?? Self.budgetBytes(capMiB: DownloadBufferPolicy.savedCapMiB(defaults: .standard)))
        if monitorsPressure {
            var size = MemoryLayout<UInt32>.size
            _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                queue: DispatchQueue.global(qos: .utility))
            pressureSource = source
            source.setEventHandler { [weak self, weak source] in
                guard let source else { return }
                var level: UInt32 = 1, size = MemoryLayout<UInt32>.size
                if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 {
                    level = source.data.contains(.critical) ? 4 : source.data.contains(.warning) ? 2 : 1
                }
                self?.setPressure(level)
            }
            source.activate()
        }
    }
    deinit { pressureSource?.cancel() }
    var limitBytes: Int64 { lock.lock(); defer { lock.unlock() }; return limit }
    var residentBytes: Int64 { lock.lock(); defer { lock.unlock() }; return used }
    var availableBytes: Int64 { lock.lock(); defer { lock.unlock() }; return max(0, limit - used) }
    var isUnderPressure: Bool { lock.lock(); defer { lock.unlock() }; return pressure >= 2 }
    var permitsReadAhead: Bool {
        lock.lock(); defer { lock.unlock() }
        return pressure < 2 && used < limit && ProcessInfo.processInfo.systemUptime >= readAheadBlockedUntil
    }

    func configure(capMiB: Int) { setLimit(Self.budgetBytes(capMiB: capMiB)) }
    func setLimit(_ bytes: Int64) {
        lock.lock()
        limit = max(1, bytes)
        let purge = used > limit ? cleanups.values.map(\.purge) : []
        lock.unlock()
        for cleanup in purge { NativeFileWork.performMemoryCleanup(cleanup) }
    }
    func setPressure(_ level: UInt32) {
        lock.lock()
        let becameCritical = pressure < 4 && level >= 4
        pressure = level
        let purge = becameCritical ? cleanups.values.map(\.purge) : []
        lock.unlock()
        for cleanup in purge { NativeFileWork.performMemoryCleanup(cleanup) }
    }
    func registerCleanup(residentBytes: @escaping @Sendable () -> Int64,
                         reclaim: @escaping @Sendable () -> Void,
                         _ cleanup: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(); lock.lock()
        cleanups[id] = .init(purge: cleanup, reclaim: reclaim, residentBytes: residentBytes)
        lock.unlock(); return id
    }
    func unregisterCleanup(_ id: UUID) { lock.lock(); cleanups[id] = nil; lock.unlock() }
    func setPriority(_ priority: Int, for id: UUID, gracePeriod: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        cleanups[id]?.priority = priority
        cleanups[id]?.protectedUntil = ProcessInfo.processInfo.systemUptime + gracePeriod
    }
    func canReclaim(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cleanups[id].map { $0.protectedUntil <= ProcessInfo.processInfo.systemUptime } ?? false
    }
    /// A second window must be able to start even if the first filled RAM.
    /// Never call another cache while holding this ledger or the caller's lock:
    /// reclamation runs on the cleanup queue, with speculative files first.
    func requestRoom(excluding owner: UUID) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRoomRequest >= 0.25 else { lock.unlock(); return }
        lastRoomRequest = now; readAheadBlockedUntil = now + 1
        let candidates = cleanups.filter { $0.key != owner && $0.value.protectedUntil <= now }
            .map(\.value).sorted { $0.priority < $1.priority }
        lock.unlock()
        NativeFileWork.performMemoryCleanup {
            if let victim = candidates.first(where: { $0.residentBytes() > 0 }) { victim.reclaim() }
        }
    }
    func reserve(_ bytes: Int64, background: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0,
              (!background || (pressure < 2 && ProcessInfo.processInfo.systemUptime >= readAheadBlockedUntil)),
              bytes <= max(0, limit - used) else { return false }
        used += bytes; return true
    }
    func release(_ bytes: Int64) { lock.lock(); used = max(0, used - bytes); lock.unlock() }

    /// Mapped blocks return their pages to macOS immediately when dropped.
    static func copy(_ data: Data) -> Data? {
        guard !data.isEmpty,
              let mapping = mmap(nil, data.count, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              mapping != MAP_FAILED else { return nil }
        data.copyBytes(to: mapping.assumingMemoryBound(to: UInt8.self), count: data.count)
        return Data(bytesNoCopy: mapping, count: data.count, deallocator: .unmap)
    }
}

/// A quick accidental selection can be undone without downloading again.
/// Taking an entry cancels its original deadline; repeated departures get a fresh two seconds.
@MainActor final class PreviewBufferRetention<Key: Hashable, Value> {
    private var entries: [Key: (Value, Task<Void, Never>)] = [:]
    var delayNanoseconds: UInt64 = 2_000_000_000
    let dispose: (Value) -> Void
    init(dispose: @escaping (Value) -> Void) { self.dispose = dispose }
    func insert(_ value: Value, for key: Key) {
        remove(key)
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: self?.delayNanoseconds ?? 0) } catch { return }
            guard !Task.isCancelled else { return }
            self?.remove(key)
        }
        entries[key] = (value, task)
    }
    func take(_ key: Key) -> Value? {
        guard let (value, task) = entries.removeValue(forKey: key) else { return nil }
        task.cancel(); return value
    }
    func remove(_ key: Key) {
        guard let value = take(key) else { return }; dispose(value)
    }
    func removeAll() { for key in Array(entries.keys) { remove(key) } }
}
