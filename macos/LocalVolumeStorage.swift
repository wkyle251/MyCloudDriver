import Combine
import Foundation

/// Capacity of the volume holding a chosen folder or disk. These numbers describe the whole
/// volume, never the folder: choosing /Volumes/G-DRIVE/Movies still reports G-DRIVE.
struct LocalVolumeCapacity: Equatable, Sendable {
    let name: String?
    let total: UInt64
    let available: UInt64

    /// Rejects a volume that reports no size or a negative figure, so the sidebar shows
    /// "unavailable" instead of an invented 0 B disk. Available space is capped at the total.
    init?(name: String?, total: Int64?, available: Int64?) {
        guard let total, total > 0, let available, available >= 0 else { return nil }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.flatMap { $0.isEmpty ? nil : $0 }
        self.total = UInt64(total)
        self.available = min(UInt64(available), UInt64(total))
    }

    var used: UInt64 { total - available }
    var usedFraction: Double { Double(used) / Double(total) }
}

enum LocalVolumeCapacityReader {
    /// Metadata only; never lists the volume. Finder's "available" figure includes space macOS can
    /// reclaim, but non-APFS external disks may report only the plain figure, so take the larger.
    static func read(_ url: URL) -> LocalVolumeCapacity? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let available = [values.volumeAvailableCapacityForImportantUsage, values.volumeAvailableCapacity.map { Int64($0) }]
            .compactMap { $0 }.max()
        return LocalVolumeCapacity(name: values.volumeName, total: values.volumeTotalCapacity.map { Int64($0) },
            available: available)
    }
}

@MainActor final class LocalVolumeStorageModel: ObservableObject {
    @Published private(set) var capacity: LocalVolumeCapacity?
    @Published private(set) var isRefreshing = false
    @Published private(set) var checkedAt: Date?
    private let read: @Sendable (URL) -> LocalVolumeCapacity?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var currentURL: URL?

    init(read: @escaping @Sendable (URL) -> LocalVolumeCapacity? = { LocalVolumeCapacityReader.read($0) }) {
        self.read = read
    }

    /// The read runs off the main thread because a sleeping or slow external disk can block. A newer
    /// request or `clear()` supersedes an older one, so a result for a previous disk is never shown.
    @discardableResult func refresh(for url: URL?) -> Task<Void, Never>? {
        guard let url else { clear(); return nil }
        if url != currentURL { capacity = nil; checkedAt = nil }
        currentURL = url
        task?.cancel()
        let id = UUID(); generation = id
        isRefreshing = true
        let read = read
        let request = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { read(url) }.value
            guard let self, generation == id, !Task.isCancelled else { return }
            capacity = result; checkedAt = Date(); isRefreshing = false; task = nil
        }
        task = request
        return request
    }

    func clear() {
        generation = UUID(); task?.cancel(); task = nil; currentURL = nil
        capacity = nil; checkedAt = nil; isRefreshing = false
    }
}
