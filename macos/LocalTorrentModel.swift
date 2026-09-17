import AppKit
import Combine
import Foundation

enum LocalTorrentSource {
    static func infoHash(_ source: String) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 16_384, let url = URLComponents(string: text), url.scheme?.lowercased() == "magnet",
              let value = url.queryItems?.first(where: { $0.name == "xt" && $0.value?.lowercased().hasPrefix("urn:btih:") == true })?.value else { return nil }
        let hash = String(value.dropFirst(9))
        if hash.range(of: #"^[A-Fa-f0-9]{40}$"#, options: .regularExpression) != nil { return hash.lowercased() }
        guard hash.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0, bits = 0, bytes: [UInt8] = []
        for character in hash.uppercased() {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(digit); bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8((buffer >> bits) & 255)) }
        }
        return bytes.count == 20 ? bytes.map { String(format: "%02x", $0) }.joined() : nil
    }

    static func selectionString(_ indexes: [Int]) throws -> String {
        let values = Array(Set(indexes)).sorted()
        guard !values.isEmpty, values.count <= 200_000, values.first! > 0 else { throw LocalTorrentError.message("Select at least one file to download.") }
        var ranges: [String] = [], start = values[0], end = values[0]
        for value in values.dropFirst() {
            if end < Int.max && value == end + 1 { end = value }
            else { ranges.append(start == end ? "\(start)" : "\(start)-\(end)"); start = value; end = value }
        }
        ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
        return ranges.joined(separator: ",")
    }

    static func name(_ magnet: String) -> String {
        let value = URLComponents(string: magnet)?.queryItems?.first(where: { $0.name == "dn" })?.value ?? "Magnet download"
        return String(value.prefix(200))
    }
    static func folderName(_ name: String, id: UUID) -> String {
        let cleaned = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0) ? String($0) : "_" }.joined().prefix(70))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return "\(cleaned.isEmpty ? "Torrent" : cleaned)-\(id.uuidString.prefix(8))"
    }
}

struct LocalTorrentFile: Codable, Identifiable, Equatable {
    let index: Int
    let path: String
    let length: UInt64
    var id: Int { index }
}

enum LocalTorrentPhase: String, Codable {
    case metadata, choosing, downloading, uploading, paused, completed, failed, stopped
    var active: Bool { self == .metadata || self == .downloading || self == .uploading }
}

struct LocalTorrentJob: Codable, Identifiable {
    let id: UUID
    var name: String
    var magnet: String?
    var phase: LocalTorrentPhase
    var files: [LocalTorrentFile] = []
    var selected: [Int] = []
    var relay: TorrentRelayState?
    var pieceLength: UInt64?
    var destination: String?
    var parentDirectory: String?
    var volumeID: String?
    var bookmark: Data?
    var completed: UInt64 = 0
    var total: UInt64 = 0
    var downloadSpeed: UInt64 = 0
    var uploadSpeed: UInt64 = 0
    /// Peers past the BitTorrent handshake, not sockets aria2 has opened.
    var peers = 0
    var seeders = 0
    /// Connection attempts in flight. Optional so queues saved by earlier
    /// builds, which have no such key, still decode.
    var attempted: Int?
    /// When the download last went quiet. Cleared by any byte of progress.
    var stalledSince: Date?
    var message = ""
    var createdAt = Date()
    var status: String {
        switch phase {
        case .metadata: return "Loading file list"
        case .choosing: return "Choose files"
        case .downloading:
            if downloadSpeed > 0 { return "Downloading" }
            return peers > 0 ? "Connected — waiting for pieces" : "Looking for peers"
        case .uploading: return relay?.stage == "hashing" ? "Preparing upload" : "Uploading to PikPak"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
    var progress: Double { total == 0 ? (phase == .completed ? 1 : 0) : min(1, Double(completed) / Double(total)) }
    var canChoose: Bool { !files.isEmpty && destination == nil && relay == nil && !phase.active }

    mutating func updateTransferStats(_ status: LocalTorrentStatus) {
        guard status.state == "active" else { clearTransferStats(); return }
        downloadSpeed = status.downloadSpeed; uploadSpeed = status.uploadSpeed
        attempted = status.connections
        seeders = status.seeders
        // A handshaked peer is always one of aria2's open sockets, so the
        // cached census cannot outlive them: dropping to no sockets means no
        // connected peers right now, without waiting for the next census.
        peers = min(peers, status.connections)
        if downloadSpeed > 0 { stalledSince = nil } else if stalledSince == nil { stalledSince = Date() }
    }
    /// Connected peers come from a separate, less frequent call, so they are
    /// applied on their own rather than overwritten by every status refresh.
    mutating func updatePeerCensus(_ census: LocalTorrentPeerCensus) {
        peers = census.connected; attempted = census.attempted
    }
    mutating func clearTransferStats() {
        downloadSpeed = 0; uploadSpeed = 0; peers = 0; seeders = 0
        attempted = nil; stalledSince = nil
    }

    /// Why nothing is arriving, once it has been quiet long enough to matter.
    /// Without this the card reads "connecting" forever and a swarm this Mac
    /// cannot reach looks the same as one that is merely slow.
    func stallNote(portMapping: TorrentPortMapState) -> String? {
        guard phase == .downloading, downloadSpeed == 0, let since = stalledSince else { return nil }
        let quiet = Date().timeIntervalSince(since)
        guard quiet >= 90 else { return nil }
        let waited = LocalTorrentFormat.duration(quiet)
        if peers > 0 { return "Connected to \(peers) \(peers == 1 ? "peer" : "peers") for \(waited), but none has sent a piece yet." }
        var note = "No peer has completed a connection in \(waited)."
        if let attempted, attempted > 0 { note += " \(attempted) \(attempted == 1 ? "attempt is" : "attempts are") in flight; peers behind NAT cannot answer." }
        switch portMapping {
        case .mapped: note += " This Mac is reachable for incoming peers."
        case .unsupported: note += " The router did not offer automatic port mapping, so peers cannot connect in — forward the torrent port to speed this up."
        case .failed(let reason): note += " " + reason
        case .idle: break
        }
        return note
    }
}

struct LocalTorrentStore {
    static let maximumMetadataBytes = 32 * 1024 * 1024
    let directory: URL
    struct Saved: Codable { let version: Int; let jobs: [LocalTorrentJob] }

    static func protect(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700]) }
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory.path)
    }
    static func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path)
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximum else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url)
    }
    func jobDirectory(_ id: UUID) throws -> URL {
        try Self.protect(directory)
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.protect(folder); return folder
    }
    func load() throws -> [LocalTorrentJob] {
        try Self.protect(directory)
        let file = directory.appendingPathComponent("queue-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let saved = try JSONDecoder().decode(Saved.self, from: Self.read(file, maximum: 64 * 1024 * 1024))
        guard saved.version == 1, Set(saved.jobs.map(\.id)).count == saved.jobs.count else { throw CocoaError(.fileReadCorruptFile) }
        return saved.jobs.map { value in
            var job = value
            if job.phase.active { job.phase = .paused; job.message = "Resume to continue from saved progress." }
            job.clearTransferStats()
            return job
        }
    }
    func save(_ jobs: [LocalTorrentJob]) throws {
        try Self.protect(directory)
        let data = try JSONEncoder().encode(Saved(version: 1, jobs: jobs))
        guard data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try Self.write(data, to: directory.appendingPathComponent("queue-v1.json"))
    }
}

/// Local torrents belong to this Mac, independently of PikPak account/mode.
/// Only metadata is fetched until the user selects files and starts a download.
@MainActor final class LocalTorrentModel: ObservableObject {
    static let shared = LocalTorrentModel()
    @Published var jobs: [LocalTorrentJob] = []
    @Published var busy = Set<UUID>()
    @Published var error: String?
    /// Whether incoming peers can reach this Mac. Explains a stalled swarm.
    @Published private(set) var portMapping: TorrentPortMapState = .idle
    /// Connected-peer counts come from `aria2.getPeers`, whose reply carries a
    /// piece bitfield per peer, so it is polled far less often than status.
    private var censusAt: [UUID: Date] = [:]
    var censusInterval: TimeInterval = 5
    private(set) var storageAvailable = true
    let store: LocalTorrentStore
    let engine: LocalTorrentDriving
    var gids: [UUID: String] = [:]
    var leases: [UUID: LocalFileAccessLease] = [:]
    var preparations: [UUID: Task<Void, Never>] = [:]
    var pendingStops = Set<UUID>()
    var polling: Task<Void, Never>?
    var closed = false
    var metadataRetryAt: [UUID: Date] = [:]
    static let metadataRetryDelay: TimeInterval = 15

    var ram: TorrentRAMDriving
    var relayUploaderFactory: () -> TorrentRelayUploading = { TorrentRelayUpload() }
    var relayContextProvider: (() -> PikPakManagementContext?)?
    var relayFilesChanged: (() -> Void)?
    var relayTasks: [UUID: Task<Void, Never>] = [:]
    var relayUploaders: [UUID: TorrentRelayUploading] = [:]
    var relayGenerations: [UUID: UUID] = [:]
    var relayLastProgress: [UUID: (Date, UInt64)] = [:]
    /// Completed files waiting for their uploader spawn, and when the oldest of
    /// them started waiting. Uploading one file per spawn wastes a process and
    /// a folder lookup; waiting for the whole batch defeats the purpose.
    var relayQueued: [UUID: Set<Int>] = [:]
    var relayQueuedSince: [UUID: Date] = [:]
    /// Per-file status is far heavier than the plain poll — a `files:true` reply
    /// for 14,623 files is megabytes — so it runs on the census cadence while
    /// speeds and peers keep refreshing every second.
    var relayFileCensusAt: [UUID: Date] = [:]
    var relayFileCensusInterval: TimeInterval = 5
    /// How long a completed file waits for company before it is uploaded alone.
    var relayFlushWait: TimeInterval = TorrentRelayDrain.flushWait

    init(directory: URL? = nil, engine: LocalTorrentDriving? = nil, ram: TorrentRAMDriving? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyCloudDriver/LocalTorrents", isDirectory: true)
        store = .init(directory: root)
        self.ram = ram ?? TorrentRAMDisk()
        self.engine = engine ?? Aria2TorrentEngine(directory: root.appendingPathComponent("Engine", isDirectory: true))
        do { jobs = try store.load() }
        catch { storageAvailable = false; self.error = "Saved local torrents could not be read. Their files have been kept. \(error.localizedDescription)" }
    }

    func job(_ id: UUID) -> LocalTorrentJob? { jobs.first { $0.id == id } }
    func edit(_ id: UUID, _ body: (inout LocalTorrentJob) -> Void) { if let index = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[index]) } }
    func save() throws { guard storageAvailable else { throw LocalTorrentError.message("Saved torrent state is unavailable.") }; try store.save(jobs) }
    func saveOrReport() { do { try save() } catch { self.error = "Could not save torrent progress: \(error.localizedDescription)" } }
    func finishOperation(_ id: UUID) {
        busy.remove(id)
        if pendingStops.remove(id) != nil, !closed { Task { await stop(id) } }
    }

    func add(magnet: String) throws -> UUID {
        guard storageAvailable, !closed, LocalTorrentSource.infoHash(magnet) != nil else { throw LocalTorrentError.message("Enter a valid BitTorrent magnet link.") }
        let source = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = jobs.first(where: { $0.magnet.flatMap(LocalTorrentSource.infoHash) == LocalTorrentSource.infoHash(source) && $0.phase != .stopped && $0.phase != .failed }) { return existing.id }
        let value = LocalTorrentJob(id: UUID(), name: LocalTorrentSource.name(source), magnet: source, phase: .metadata)
        jobs.append(value)
        do { try save() } catch { jobs.removeAll { $0.id == value.id }; throw error }
        launchPreparation(value.id); return value.id
    }
    func add(torrent: URL) throws -> UUID {
        guard storageAvailable, !closed else { throw LocalTorrentError.message("Local torrent state is unavailable.") }
        let lease = LocalFileAccessLease([torrent]); defer { withExtendedLifetime(lease) {} }
        let data = try LocalTorrentStore.read(torrent, maximum: LocalTorrentStore.maximumMetadataBytes)
        let value = LocalTorrentJob(id: UUID(), name: torrent.deletingPathExtension().lastPathComponent, phase: .metadata)
        try LocalTorrentStore.write(data, to: store.jobDirectory(value.id).appendingPathComponent("source.torrent"))
        jobs.append(value)
        do { try save() } catch { jobs.removeAll { $0.id == value.id }; throw error }
        launchPreparation(value.id); return value.id
    }

    private func launchPreparation(_ id: UUID) {
        preparations[id] = Task { [weak self] in await self?.prepare(id) }
    }
    func connect() async throws {
        if !engine.running { engineDidStop() }
        try await engine.start()
        guard !closed else { engine.stop(); throw CancellationError() }
    }
    private func engineDidStop() {
        guard !gids.isEmpty else { return }
        for id in gids.keys where job(id)?.phase.active == true {
            if job(id)?.phase == .metadata, job(id)?.magnet != nil { scheduleMetadataRetry(id) }
            else { edit(id) { $0.phase = .paused; $0.clearTransferStats(); $0.message = "Torrent engine stopped. Resume to continue." } }
        }
        gids.removeAll(); leases.removeAll(); saveOrReport()
    }
    private func scheduleMetadataRetry(_ id: UUID) {
        metadataRetryAt[id] = Date().addingTimeInterval(Self.metadataRetryDelay)
        edit(id) { $0.phase = .metadata; $0.clearTransferStats(); $0.message = "Still waiting for peers. Retrying the file list automatically in 15 seconds…" }
        saveOrReport()
    }
    private func prepare(_ id: UUID, retrying: Bool = false) async {
        guard let job = job(id), !busy.contains(id), !closed else { return }
        busy.insert(id); edit(id) { $0.phase = .metadata; $0.clearTransferStats(); $0.message = "Finding peers for the file list…" }; error = nil
        defer { finishOperation(id); preparations[id] = nil }
        do {
            let folder = try store.jobDirectory(id)
            try await connect()
            edit(id) { $0.phase = .metadata }
            if let previous = gids[id] { try await engine.remove(previous); gids[id] = nil }
            let source = folder.appendingPathComponent("source.torrent")
            if FileManager.default.fileExists(atPath: source.path) {
                let data = try LocalTorrentStore.read(source, maximum: LocalTorrentStore.maximumMetadataBytes)
                let gid = try await engine.addTorrent(data, directory: folder, selection: nil)
                gids[id] = gid
                try await acceptManifest(id, gid: gid)
            } else if let magnet = job.magnet {
                gids[id] = try await engine.addMagnet(magnet, directory: folder)
            } else { throw LocalTorrentError.message("The saved torrent file is unavailable. Open the .torrent file again.") }
            guard !closed else { return }
            metadataRetryAt[id] = nil
            try save(); startPolling()
        } catch {
            if !closed {
                if retrying { scheduleMetadataRetry(id) }
                else { edit(id) { $0.phase = .failed; $0.message = error.localizedDescription }; saveOrReport() }
            }
        }
    }

    private func acceptManifest(_ id: UUID, gid: String) async throws {
        let status = try await engine.status(gid, files: true)
        guard !closed, job(id) != nil else { return }
        let root = try store.jobDirectory(id).standardizedFileURL.path + "/"
        guard status.state == "paused", !status.files.isEmpty, status.files.count <= 200_000 else {
            throw LocalTorrentError.message("The torrent file list is unavailable or too large to display safely.")
        }
        let files = try status.files.map { file -> LocalTorrentFile in
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            guard path.hasPrefix(root), path.count > root.count else { throw LocalTorrentError.message("The torrent contains a path outside its download folder.") }
            return .init(index: file.index, path: String(path.dropFirst(root.count)), length: file.length)
        }
        guard Set(files.map(\.index)).count == files.count else { throw LocalTorrentError.message("The torrent contains duplicate file indexes.") }
        edit(id) { $0.name = status.name; $0.pieceLength = status.pieceLength; $0.files = files; $0.selected = files.map(\.index); $0.phase = .choosing; $0.clearTransferStats(); $0.message = "Choose files and a destination to start."; $0.total = status.total }
        metadataRetryAt[id] = nil
    }

    func download(_ id: UUID, selected: Set<Int>, to parent: URL) async {
        guard let job = job(id), !busy.contains(id), !job.files.isEmpty, job.destination == nil, job.relay == nil, !closed else { return }
        busy.insert(id); error = nil
        defer { finishOperation(id) }
        do {
            guard !selected.isEmpty, selected.isSubset(of: Set(job.files.map(\.index))) else { throw LocalTorrentError.message("Select at least one file from this torrent.") }
            let lease = LocalFileAccessLease([parent]); leases[id] = lease
            try LocalFileAccess.validate(parent, directory: true, writing: true)
            let destination = parent.appendingPathComponent(LocalTorrentSource.folderName(job.name, id: id), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw LocalTorrentError.message("The download folder already exists. Choose another destination.") }
            let total = try selectedTotal(job.files.filter { selected.contains($0.index) })
            let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let available, total > UInt64(max(0, available)) { throw LocalTorrentError.message("The selected files need more space than this disk has available. Choose fewer files or another disk.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let bookmark = try? parent.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
            edit(id) { $0.destination = destination.path; $0.parentDirectory = parent.path; $0.volumeID = LocalFileAccess.volumeID(parent); $0.bookmark = bookmark; $0.selected = selected.sorted(); $0.total = total; $0.message = "" }
            try save()
            try await begin(id)
        } catch { self.error = error.localizedDescription; if self.job(id)?.phase != .downloading { edit(id) { $0.message = error.localizedDescription } }; saveOrReport() }
    }

    func resume(_ id: UUID) async {
        guard let value = job(id), !busy.contains(id), !value.phase.active, !closed else { return }
        if value.relay != nil { await resumeRelay(id); return }
        if value.files.isEmpty { launchPreparation(id); return }
        guard value.destination != nil else { return }
        busy.insert(id); error = nil; defer { finishOperation(id) }
        do { try await begin(id) }
        catch { self.error = error.localizedDescription; edit(id) { $0.message = error.localizedDescription }; saveOrReport() }
    }
    private func begin(_ id: UUID) async throws {
        guard let value = job(id), let path = value.destination, let parentPath = value.parentDirectory else { return }
        let destination = URL(fileURLWithPath: path), parent = URL(fileURLWithPath: parentPath)
        leases[id] = LocalFileAccessLease([parent], bookmarks: value.bookmark.map { [parentPath:$0] } ?? [:])
        try LocalFileAccess.validate(parent, volumeID: value.volumeID, directory: true, writing: true)
        try LocalFileAccess.validate(destination, volumeID: value.volumeID, directory: true, writing: true)
        guard destination.resolvingSymlinksInPath().path.hasPrefix(parent.resolvingSymlinksInPath().path + "/") else { throw LocalTorrentError.message("The download folder changed. Restore the original folder before resuming.") }
        try await connect()
        if let gid = gids[id] {
            let status = try await engine.status(gid, files: false)
            if ["error", "removed", "complete"].contains(status.state) { try await engine.remove(gid); gids[id] = nil }
        }
        if gids[id] == nil {
            let data = try LocalTorrentStore.read(store.jobDirectory(id).appendingPathComponent("source.torrent"), maximum: LocalTorrentStore.maximumMetadataBytes)
            gids[id] = try await engine.addTorrent(data, directory: destination, selection: value.selected)
        }
        guard let gid = gids[id], !closed else { return }
        edit(id) { $0.phase = .downloading; $0.message = "" }
        try save(); startPolling()
        // Mark the job as monitored before unpausing: an ambiguous RPC result
        // must not leave an actual download running outside the progress list.
        try await engine.begin(gid, directory: destination, selection: value.selected)
    }

    func pause(_ id: UUID) async {
        if job(id)?.relay != nil { await pauseRelay(id); return }
        guard !busy.contains(id), job(id)?.phase.active == true else { return }
        busy.insert(id); defer { finishOperation(id) }
        do {
            if let gid = gids[id], engine.running {
                if metadataRetryAt[id] != nil { try await engine.remove(gid); gids[id] = nil }
                else { try await engine.pause(gid) }
            }
            metadataRetryAt[id] = nil
            edit(id) { $0.phase = .paused; $0.clearTransferStats(); $0.message = "" }; saveOrReport()
        }
        catch { self.error = error.localizedDescription }
    }
    func stop(_ id: UUID) async {
        if job(id)?.relay != nil { await stopRelay(id); return }
        if busy.contains(id) { pendingStops.insert(id); return }
        busy.insert(id); defer { busy.remove(id) }
        do {
            if let gid = gids[id], engine.running { try await engine.remove(gid) }
            gids[id] = nil; leases[id] = nil; metadataRetryAt[id] = nil
            edit(id) { $0.phase = .stopped; $0.clearTransferStats(); $0.message = "Downloaded and partial files are kept on disk." }
            saveOrReport()
        } catch { self.error = error.localizedDescription }
    }
    func remove(_ id: UUID) async {
        await stop(id)
        guard job(id)?.phase == .stopped else { return }
        let previous = jobs
        jobs.removeAll { $0.id == id }
        do {
            try save()
            // This private UUID folder contains metadata only. Payload lives
            // in the separately chosen destination and is never removed here.
            let metadata = store.directory.appendingPathComponent(id.uuidString)
            try? FileManager.default.removeItem(at: metadata)
        } catch { jobs = previous; self.error = "Could not remove the saved torrent: \(error.localizedDescription)" }
    }
    func reveal(_ id: UUID) {
        guard let path = job(id)?.destination, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func startPolling() {
        guard polling == nil, !closed else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    /// Updates the connected-peer count on its own slower cadence.
    func refreshCensus(_ id: UUID, gid: String, attempted: Int) async {
        // Only an active download has peers; anything else just cleared its stats.
        let now = Date()
        if let last = censusAt[id], now.timeIntervalSince(last) < censusInterval { return }
        censusAt[id] = now
        guard let census = try? await engine.peerCensus(gid, attempted: attempted) else { return }
        guard !closed, gids[id] == gid, job(id)?.phase.active == true else { return }
        edit(id) { $0.updatePeerCensus(census) }
    }

    func refresh() async {
        if !engine.running { engineDidStop() }
        portMapping = engine.portMapping
        for value in jobs where value.phase.active && !busy.contains(value.id) {
            if value.phase == .metadata, let retryAt = metadataRetryAt[value.id] {
                if Date() >= retryAt { await prepare(value.id, retrying: true) }
                continue
            }
            if value.relay != nil { await refreshRelay(value.id); continue }
            guard !closed, engine.running, let gid = gids[value.id] else { continue }
            let id = value.id
            var retryMetadataOnError = value.phase == .metadata && value.magnet != nil
            do {
                let status = try await engine.status(gid, files: false)
                guard !closed, gids[id] == gid, job(id)?.phase.active == true, !busy.contains(id) else { continue }
                edit(id) { $0.updateTransferStats(status) }
                if status.state == "active" { await refreshCensus(id, gid: gid, attempted: status.connections) }
                guard !closed, gids[id] == gid, job(id)?.phase.active == true, !busy.contains(id) else { continue }
                if value.phase == .metadata {
                    if status.state == "complete" {
                        retryMetadataOnError = false
                        busy.insert(id)
                        defer { finishOperation(id) }
                        guard let hash = value.magnet.flatMap(LocalTorrentSource.infoHash) else { throw LocalTorrentError.message("Torrent metadata could not be identified.") }
                        let directory = try store.jobDirectory(id)
                        let data = try LocalTorrentStore.read(directory.appendingPathComponent(hash + ".torrent"), maximum: LocalTorrentStore.maximumMetadataBytes)
                        try LocalTorrentStore.write(data, to: directory.appendingPathComponent("source.torrent"))
                        try await engine.remove(gid)
                        let next = try await engine.addTorrent(data, directory: directory, selection: nil)
                        gids[id] = next
                        do { try await acceptManifest(id, gid: next); try save() }
                        catch { edit(id) { $0.phase = .failed; $0.message = error.localizedDescription }; saveOrReport() }
                    } else if ["error", "removed", "paused"].contains(status.state) { scheduleMetadataRetry(id) }
                    else if status.state == "waiting" {
                        edit(id) { $0.message = "Queued for a free torrent slot…" }
                    } else { edit(id) { $0.message = "Waiting for peers to share the file list. Will keep trying until paused or stopped…" } }
                } else {
                    let mapping = portMapping
                    edit(id) {
                        $0.completed = status.completed; $0.total = status.total
                        $0.message = status.state == "waiting" ? "Queued — up to three torrents run at once." : ($0.stallNote(portMapping: mapping) ?? "")
                        if status.state == "complete" { $0.phase = .completed; $0.completed = $0.total; $0.message = "Saved to this Mac. Seeding has stopped." }
                        else if status.state == "paused" { $0.phase = .paused }
                        else if status.state == "error" { $0.phase = .failed; $0.message = status.error }
                        else if status.state == "removed" { $0.phase = .stopped }
                    }
                    if job(id)?.phase.active == false { leases[id] = nil; saveOrReport() }
                }
            } catch {
                if !closed, gids[id] == gid, job(id)?.phase.active == true {
                    edit(id) { $0.clearTransferStats() }
                    if retryMetadataOnError { scheduleMetadataRetry(id) }
                    else if !engine.running { edit(id) { $0.phase = .paused; $0.message = "Torrent engine stopped. Resume to continue." }; gids[id] = nil; saveOrReport() }
                    else if value.phase == .metadata { edit(id) { $0.phase = .failed; $0.message = error.localizedDescription }; saveOrReport() }
                    else { edit(id) { $0.message = "Reconnecting to download status…" } }
                }
            }
        }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true; polling?.cancel(); polling = nil
        metadataRetryAt.removeAll()
        preparations.values.forEach { $0.cancel() }; preparations.removeAll()
        relayGenerations.removeAll()
        relayUploaders.values.forEach { $0.stop() }
        relayTasks.values.forEach { $0.cancel() }; relayTasks.removeAll()
        for index in jobs.indices where jobs[index].phase.active { jobs[index].phase = .paused; jobs[index].clearTransferStats() }
        saveOrReport(); engine.stop(); gids.removeAll(); leases.removeAll()
    }
    func selectedTotal(_ files: [LocalTorrentFile]) throws -> UInt64 {
        try files.reduce(0) { total, file in
            let (value, overflow) = total.addingReportingOverflow(file.length)
            if overflow { throw LocalTorrentError.message("The torrent reports an invalid total size.") }
            return value
        }
    }
}
