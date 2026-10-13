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
    /// Optional for queues written before native padding flags were exposed.
    var padding: Bool? = nil
    var isPadding: Bool { padding == true }
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
    /// Optional for older queues. A user pause/stop is durable; an unexpected
    /// interruption remains eligible to resume, including after app restart.
    var automaticallyResume: Bool? = nil
    var retryAttempt: Int? = nil
    var retryAt: Date? = nil
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
    /// Upload to BitTorrent peers. A relay job seeds while it fills RAM, so
    /// this is reported separately from the PikPak rate below.
    var uploadSpeed: UInt64 = 0
    /// Upload from RAM to PikPak on a relay job, which runs alongside the
    /// torrent rather than taking turns with it. Optional so queues saved by
    /// earlier builds, which have no such key, still decode.
    var relayUploadSpeed: UInt64?
    /// Peers past the BitTorrent handshake, not sockets aria2 has opened.
    var peers = 0
    var seeders = 0
    /// Connection attempts in flight. Optional so queues saved by earlier
    /// builds, which have no such key, still decode.
    var attempted: Int?
    /// When the download last went quiet. Cleared by any byte of progress.
    var stalledSince: Date?
    /// Optional for saved queues from builds without verification telemetry.
    var checkingPieces: Bool?
    /// How far the running hash check has read. Nil while it waits for a slot,
    /// so a queued check still reads as plain progressless wording.
    var checkingFraction: Double?
    /// "Checking downloaded pieces", with the figure once there is one.
    var checkingPiecesLabel: String { "Checking downloaded pieces" + checkingPercentSuffix }
    /// The same, worded for the card message underneath.
    var checkingPiecesMessage: String {
        checkingFraction == nil ? "Checking downloaded pieces before continuing…"
                                : "Checking downloaded pieces before continuing" + checkingPercentSuffix
    }
    private var checkingPercentSuffix: String {
        guard let checkingFraction else { return "" }
        return " — \(Int((checkingFraction * 100).rounded()))%"
    }
    var message = ""
    var createdAt = Date()
    var status: String {
        switch phase {
        case .metadata: return "Loading file list"
        case .choosing: return "Choose files"
        case .downloading:
            if checkingPieces == true { return checkingPiecesLabel }
            if relay != nil, total > 0, downloadedBytes >= total { return "Download complete — waiting for PikPak" }
            if relay?.waitingForUploadSpace == true { return "Waiting for buffer space" }
            if downloadSpeed > 0 { return "Downloading" }
            return peers > 0 ? "Connected — waiting for pieces" : "Looking for peers"
        case .uploading: return relay?.stage == "hashing" ? "Preparing upload" : "Uploading to PikPak"
        case .paused: return retryAt == nil ? "Paused" : "Waiting to retry"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
    var progress: Double { total == 0 ? (phase == .completed ? 1 : 0) : min(1, Double(completed) / Double(total)) }
    var downloadedBytes: UInt64 { min(total, max(completed, relay?.downloadedBytes ?? completed)) }
    /// Logical download bytes and cloud receipts count each selected byte once.
    /// Allocated disk space also includes uploaded copies retained for peers.
    var downloadedAwaitingPikPakBytes: UInt64 {
        guard relay != nil else { return 0 }
        return downloadedBytes - min(downloadedBytes, completed)
    }
    var downloadProgress: Double { total == 0 ? (phase == .completed ? 1 : 0) : Double(downloadedBytes) / Double(total) }
    var downloadETA: TimeInterval? {
        guard phase.active, total > downloadedBytes, downloadSpeed > 0 else { return nil }
        return Double(total - downloadedBytes) / Double(downloadSpeed)
    }
    var downloadEstimate: String {
        if total > 0, downloadedBytes >= total { return "Download complete" }
        if phase == .paused { return "Paused" }
        guard let downloadETA else { return "Download ETA —" }
        return "Download ETA about " + LocalTorrentFormat.duration(downloadETA)
    }
    var canChoose: Bool { !files.isEmpty && destination == nil && relay == nil && !phase.active }
    var payloadFiles: [LocalTorrentFile] { files.filter { !$0.isPadding } }
    var savedFileCount: Int { relay?.uploaded.intersection(selected).count ?? 0 }

    /// Keep padding in the byte layout, but never select or upload it. Old
    /// cloud receipts remain intact so cleanup can identify previous padding uploads.
    mutating func excludePaddingFiles(_ indexes: Set<Int>) -> Bool {
        guard !indexes.isEmpty,
              files.contains(where: { indexes.contains($0.index) && !$0.isPadding }) || !indexes.isDisjoint(with: selected) else { return false }
        for position in files.indices where indexes.contains(files[position].index) { files[position].padding = true }
        selected.removeAll { indexes.contains($0) }
        let wanted = Set(selected)
        total = files.filter { wanted.contains($0.index) }.reduce(0) { $0 + $1.length }
        if let state = relay {
            completed = files.filter { wanted.contains($0.index) && state.uploaded.contains($0.index) }.reduce(0) { $0 + $1.length }
            relay?.selection?.removeAll { indexes.contains($0) }
            relay?.downloadedBytes = completed
        }
        return true
    }
    var canSwitchRelayToStorage: Bool { relay != nil && relay?.storage == nil && phase != .completed }
    var localFolder: String? { relay?.storage?.path ?? destination }

    /// Carry the hash check's flag and its figure together.
    ///
    /// Storage jobs arrive here through `updateTransferStats`; relay jobs refresh
    /// on their own path and set these fields directly. Both go through this, so
    /// a card cannot end up knowing a check is running but not how far along.
    mutating func applyCheckingState(_ status: LocalTorrentStatus) {
        checkingPieces = status.checkingPieces
        checkingFraction = status.checkingFraction
    }

    mutating func updateTransferStats(_ status: LocalTorrentStatus) {
        if status.checkingPieces {
            clearTransferStats(); applyCheckingState(status)
            return
        }
        guard status.state == "active" else { clearTransferStats(); return }
        checkingPieces = false
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
        downloadSpeed = 0; uploadSpeed = 0; relayUploadSpeed = nil; peers = 0; seeders = 0
        attempted = nil; stalledSince = nil; checkingPieces = nil; checkingFraction = nil
    }

    /// Why nothing is arriving, once it has been quiet long enough to matter.
    /// Without this the card reads "connecting" forever and a swarm this Mac
    /// cannot reach looks the same as one that is merely slow.
    func stallNote(portMapping: TorrentPortMapState, dns: TorrentDNSState) -> String? {
        guard phase == .downloading, checkingPieces != true, downloadSpeed == 0, let since = stalledSince else { return nil }
        let quiet = Date().timeIntervalSince(since)
        guard quiet >= 90 else { return nil }
        let waited = LocalTorrentFormat.duration(quiet)
        if peers > 0 { return "Connected to \(peers) \(peers == 1 ? "peer" : "peers") for \(waited), but none has sent a piece yet." }
        var note = "No peer has completed a connection in \(waited)."
        if let attempted, attempted > 0 { note += " \(attempted) \(attempted == 1 ? "attempt is" : "attempts are") in flight." }
        // A tunnel may route these virtual addresses successfully for TCP and
        // UDP. DNS interception is evidence of a proxy, not a failed connection.
        if case .placeholder(let address) = dns {
            return note + " A proxy is returning virtual DNS addresses (\(address)). Check whether it supports BitTorrent and UDP; these addresses alone do not show that traffic is blocked."
        }
        switch portMapping {
        case .mapped(let tcp, let udp, let address, let lease):
            guard let port = tcp else {
                return note + (udp.map { " The router accepted UDP port \($0), but an incoming TCP mapping was not confirmed." } ?? " Incoming port mapping was not confirmed.")
            }
            if udp == nil { note += " UDP mapping was not confirmed." }
            if lease == 0 { note += " The router accepted a permanent mapping; it will be removed when torrents stop." }
            // A mapping onto a private or carrier-NAT address is a door onto a
            // network that is itself behind another door. Saying "reachable"
            // there sends the reader hunting for a fault that is not theirs.
            if let address, !TorrentIPv4.isRoutable(address) {
                note += " Your router mapped port \(port), but its own address (\(address)) is behind another network. Incoming peer reachability is unconfirmed."
            } else {
                note += " An incoming port mapping on port \(port) is active; external reachability has not been verified."
            }
        case .unsupported: note += " Automatic incoming port mapping was not confirmed. Some peers may be unreachable through this router or VPN."
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
            if job.phase.active {
                if job.automaticallyResume == nil { job.automaticallyResume = true }
                job.phase = .paused; job.message = "Continuing from saved progress…"
            }
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
@MainActor private final class TorrentDNSProbeTarget {
    weak var model: LocalTorrentModel?
    init(_ model: LocalTorrentModel) { self.model = model }
}

@MainActor final class TorrentRelayAccountCandidate {
    weak var account: DownloaderModel?
    let identity: ObjectIdentifier
    init(_ account: DownloaderModel) {
        self.account = account
        identity = ObjectIdentifier(account)
    }
}

@MainActor final class LocalTorrentModel: ObservableObject {
    static let shared = LocalTorrentModel()
    @Published var jobs: [LocalTorrentJob] = []
    @Published var busy = Set<UUID>()
    @Published var error: String?
    /// Whether incoming peers can reach this Mac. Explains a stalled swarm.
    @Published private(set) var portMapping: TorrentPortMapState = .idle
    @Published private(set) var dnsState: TorrentDNSState = .unknown
    /// When the resolver was last questioned. Its answer only changes when a
    /// proxy is switched on or off, and `getaddrinfo` blocks, so this is rare.
    private var dnsProbedAt: Date?
    private let dnsProbe: @Sendable ([String]) -> TorrentDNSState
    /// The handshaked peers behind each running torrent's two summary rates.
    /// Outside `LocalTorrentJob`: live details never enter the saved queue.
    /// The engine separately caches validated public peer endpoints briefly.
    @Published private(set) var peerDetails: [UUID: [LocalTorrentPeer]] = [:]
    @Published private(set) var networkDetails: [UUID: LocalTorrentNetworkDiagnostics] = [:]
    /// Native peer rates follow each status poll. Legacy aria2 peer replies
    /// carry piece bitfields, so that engine requests a slower cadence.
    private var censusAt: [UUID: Date] = [:]
    private var networkCensusAt: [UUID: Date] = [:]
    var censusInterval: TimeInterval = 30
    private(set) var storageAvailable = true
    let store: LocalTorrentStore
    let engine: LocalTorrentDriving
    var gids: [UUID: String] = [:]
    var leases: [UUID: LocalFileAccessLease] = [:]
    var preparations: [UUID: Task<Void, Never>] = [:]
    var pendingStops = Set<UUID>()
    var polling: Task<Void, Never>?
    var closed = false
    /// Only launch-restored work is eligible. Pausing again in this session
    /// cancels its pending automatic start; Stop is never auto-resumed.
    var restoredResumeIDs = Set<UUID>()
    var relayStorageLimitChanged = Set<UUID>()
    var metadataRetryAt: [UUID: Date] = [:]
    static let metadataRetryDelay: TimeInterval = 15
    var recoveryDelays = AutomaticRecovery.delays
    private var saveRetryTask: Task<Void, Never>?

    var ram: TorrentRAMDriving
    var relayUploaderFactory: () -> TorrentRelayUploading = { TorrentRelayUpload() }
    var relayAccountCandidates: [TorrentRelayAccountCandidate] = []
    var relayContextOverride: (() -> PikPakManagementContext?)?
    /// Synthetic upload fixtures may override credential lookup. Production
    /// lookup follows all live windows, rather than only the latest window.
    var relayContextProvider: (() -> PikPakManagementContext?)? {
        get { relayContextOverride ?? { [weak self] in self?.registeredRelayContexts().first?.1 } }
        set { relayContextOverride = newValue }
    }
    var relayFilesChanged: (() -> Void)?
    var relayTasks: [UUID: Task<Void, Never>] = [:]
    var relayUploaders: [UUID: TorrentRelayUploading] = [:]
    var paddingCleanupTasks: [UUID: Task<Void, Never>] = [:]
    var paddingCleanupUploaders: [UUID: TorrentRelayUploading] = [:]
    var paddingCleanupUploaderFactory: () -> TorrentRelayUploading = { TorrentRelayUpload() }
    var relayGenerations: [UUID: UUID] = [:]
    var relayLastProgress: [UUID: (Date, UInt64)] = [:]
    var relayUploadFailures: [UUID: Int] = [:]
    var relayUploadRetryDelay: TimeInterval = 30
    /// Completed files waiting for their uploader spawn, and when the oldest of
    /// them started waiting. Uploading one file per spawn wastes a process and
    /// a folder lookup; waiting for the whole batch defeats the purpose.
    var relayQueued: [UUID: Set<Int>] = [:]
    var relayQueuedSince: [UUID: Date] = [:]
    /// Per-file status is far heavier than the plain poll — a `files:true` reply
    /// for 14,623 files is megabytes — so it runs on the census cadence while
    /// speeds and peer counts refresh together every thirty seconds.
    var relayFileCensusAt: [UUID: Date] = [:]
    var relayFileCensusInterval: TimeInterval = 30
    /// Consecutive status replies lost per job. One dropped reply from the
    /// local engine is not a failed transfer: it used to stop a RAM relay
    /// outright, and to blank a local download's swarm and rates.
    var statusFailures: [UUID: Int] = [:]
    var statusRetries = 5
    /// How long a completed file waits for company before it is uploaded alone.
    var relayFlushWait: TimeInterval = TorrentRelayDrain.flushWait

    init(dnsProbe: @escaping @Sendable ([String]) -> TorrentDNSState = { TorrentFakeIP.probe($0) },
         directory: URL? = nil, engine: LocalTorrentDriving? = nil, ram: TorrentRAMDriving? = nil) {
        self.dnsProbe = dnsProbe
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyCloudDriver/LocalTorrents", isDirectory: true)
        store = .init(directory: root)
        self.ram = ram ?? TorrentRAMDisk()
        self.engine = engine ?? LibtorrentEngine(directory: root.appendingPathComponent("Engine", isDirectory: true))
        censusInterval = self.engine.peerCensusInterval
        do {
            jobs = try store.load()
            restoredResumeIDs = Set(jobs.filter {
                $0.phase == .paused && $0.automaticallyResume == true &&
                ($0.destination != nil || $0.relay != nil || $0.files.isEmpty)
            }.map(\.id))
        }
        catch { storageAvailable = false; self.error = "Saved local torrents could not be read. Their files have been kept. \(error.localizedDescription)" }
    }

    func job(_ id: UUID) -> LocalTorrentJob? { jobs.first { $0.id == id } }
    func edit(_ id: UUID, _ body: (inout LocalTorrentJob) -> Void) { if let index = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[index]) } }
    func save() throws { guard storageAvailable else { throw LocalTorrentError.message("Saved torrent state is unavailable.") }; try store.save(jobs) }
    func saveOrReport() {
        do { try save(); saveRetryTask?.cancel(); saveRetryTask = nil }
        catch {
            self.error = "Could not save torrent progress. Retrying automatically: \(error.localizedDescription)"
            guard !closed, storageAvailable, saveRetryTask == nil else { return }
            saveRetryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, !self.closed else { return }
                self.saveRetryTask = nil; self.saveOrReport()
            }
        }
    }

    func queueRecovery(_ id: UUID, message: String) {
        guard !closed, let value = job(id), value.automaticallyResume != false,
              value.phase != .stopped, value.phase != .completed else { return }
        let attempt = value.retryAttempt ?? 0
        let delay = AutomaticRecovery.delay(attempt: attempt, schedule: recoveryDelays)
        edit(id) {
            $0.automaticallyResume = true
            $0.retryAttempt = AutomaticRecovery.nextAttempt(attempt)
            $0.retryAt = Date().addingTimeInterval(delay)
            $0.message = "Retrying automatically in \(Int(delay))s. \(message)"
        }
        saveOrReport(); startPolling()
    }

    func holdRecovery(_ id: UUID) {
        restoredResumeIDs.remove(id); metadataRetryAt[id] = nil
        edit(id) { $0.automaticallyResume = false; $0.retryAt = nil; $0.retryAttempt = nil }
        saveOrReport()
    }
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
            else {
                // Fence off the old uploader before a fresh run reconciles its
                // receipts. Keep the payload and RAM volume for that run.
                relayGenerations[id] = nil
                relayUploaders[id]?.stop(); relayTasks[id]?.cancel()
                edit(id) { $0.phase = .paused; $0.clearTransferStats() }
                queueRecovery(id, message: "Torrent engine stopped.")
            }
        }
        gids.removeAll(); leases.removeAll(); saveOrReport()
    }
    private func scheduleMetadataRetry(_ id: UUID) {
        metadataRetryAt[id] = Date().addingTimeInterval(Self.metadataRetryDelay)
        edit(id) { $0.phase = .metadata; $0.clearTransferStats(); $0.message = "Still waiting for peers. Retrying the file list automatically…" }
        saveOrReport()
    }
    private func prepare(_ id: UUID, retrying: Bool = false) async {
        guard let job = job(id), !busy.contains(id), !closed else { return }
        busy.insert(id); edit(id) { $0.phase = .metadata; $0.automaticallyResume = true; $0.clearTransferStats(); $0.message = "Finding peers for the file list…" }; error = nil
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
                if retrying && job.magnet != nil { scheduleMetadataRetry(id); startPolling() }
                else {
                    edit(id) { $0.phase = .paused }
                    queueRecovery(id, message: error.localizedDescription)
                }
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
            return .init(index: file.index, path: String(path.dropFirst(root.count)), length: file.length, padding: file.padding ? true : nil)
        }
        guard Set(files.map(\.index)).count == files.count else { throw LocalTorrentError.message("The torrent contains duplicate file indexes.") }
        // aria2 does not relocate a BitTorrent DownloadContext when `dir` is
        // changed later. Retire the metadata-only handle; the selected payload
        // must be added afresh in the chosen local folder or RAM volume.
        try await engine.remove(gid)
        gids[id] = nil
        let payload = files.filter { !$0.isPadding }
        let total = try selectedTotal(payload)
        edit(id) { $0.name = status.name; $0.pieceLength = status.pieceLength; $0.files = files; $0.selected = payload.map(\.index); $0.phase = .choosing; $0.clearTransferStats(); $0.message = "Choose files and a destination to start."; $0.total = total }
        metadataRetryAt[id] = nil
    }

    func download(_ id: UUID, selected: Set<Int>, to parent: URL) async {
        guard let job = job(id), !busy.contains(id), !job.files.isEmpty, job.destination == nil, job.relay == nil, !closed else { return }
        busy.insert(id); error = nil
        defer { finishOperation(id) }
        do {
            guard !selected.isEmpty, selected.isSubset(of: Set(job.payloadFiles.map(\.index))) else { throw LocalTorrentError.message("Select at least one file from this torrent.") }
            let lease = LocalFileAccessLease([parent]); leases[id] = lease
            try LocalFileAccess.validate(parent, directory: true, writing: true)
            let destination = parent.appendingPathComponent(LocalTorrentSource.folderName(job.name, id: id), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw LocalTorrentError.message("The download folder already exists. Choose another destination.") }
            let total = try selectedTotal(job.files.filter { selected.contains($0.index) })
            let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let available, total > UInt64(max(0, available)) { throw LocalTorrentError.message("The selected files need more space than this disk has available. Choose fewer files or another disk.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let bookmark = try? parent.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
            edit(id) { $0.destination = destination.path; $0.parentDirectory = parent.path; $0.volumeID = LocalFileAccess.volumeID(parent); $0.bookmark = bookmark; $0.selected = selected.sorted(); $0.total = total; $0.automaticallyResume = true; $0.message = "" }
            try save()
            try await begin(id)
        } catch {
            self.error = error.localizedDescription
            if self.job(id)?.destination != nil {
                if self.job(id)?.phase != .downloading { edit(id) { $0.phase = .paused } }
                queueRecovery(id, message: error.localizedDescription)
            } else { edit(id) { $0.message = error.localizedDescription }; saveOrReport() }
        }
    }

    func resume(_ id: UUID, automatic: Bool = false) async {
        guard let value = job(id), !busy.contains(id), !value.phase.active, !closed else { return }
        restoredResumeIDs.remove(id)
        edit(id) { $0.automaticallyResume = true; $0.retryAt = nil; if !automatic { $0.retryAttempt = nil } }
        if value.relay != nil { await resumeRelay(id); return }
        if value.files.isEmpty { launchPreparation(id); return }
        guard value.destination != nil else { return }
        busy.insert(id); error = nil; defer { finishOperation(id) }
        do { try await begin(id) }
        catch { self.error = error.localizedDescription; queueRecovery(id, message: error.localizedDescription) }
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
        edit(id) { $0.phase = .downloading; $0.automaticallyResume = true; $0.message = "" }
        try save(); startPolling()
        // Mark the job as monitored before unpausing: an ambiguous RPC result
        // must not leave an actual download running outside the progress list.
        try await engine.begin(gid, directory: destination, selection: value.selected)
    }

    func pause(_ id: UUID) async {
        let waitingForMetadata = metadataRetryAt[id] != nil
        holdRecovery(id)
        if job(id)?.relay != nil { await pauseRelay(id); return }
        guard !busy.contains(id), job(id)?.phase.active == true else { return }
        busy.insert(id); defer { finishOperation(id) }
        do {
            if let gid = gids[id], engine.running {
                if waitingForMetadata { try await engine.remove(gid); gids[id] = nil }
                else { try await engine.pause(gid) }
            }
            metadataRetryAt[id] = nil
            edit(id) { $0.phase = .paused; $0.clearTransferStats(); $0.message = "" }; saveOrReport()
        }
        catch { self.error = error.localizedDescription }
    }
    func stop(_ id: UUID) async {
        holdRecovery(id)
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
        guard let path = job(id)?.localFolder, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func startPolling() {
        guard polling == nil, !closed else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.closed else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }
    /// Missing status replies never pause an otherwise running engine. The
    /// normal poll cadence retries transport failures for as long as needed;
    /// the failure budget only expires stale telemetry. Repeated engine
    /// errors and an exited process still follow the ordinary error path.
    func pollStatus(_ id: UUID, gid: String, files: Bool) async throws -> LocalTorrentStatus? {
        do {
            let status = try await engine.status(gid, files: files)
            guard !closed, gids[id] == gid else { return nil }
            statusFailures[id] = nil
            return status
        } catch {
            guard !closed, gids[id] == gid else { return nil }
            guard engine.running else { throw error }
            let failures = min(statusRetries, (statusFailures[id] ?? 0) + 1)
            statusFailures[id] = failures
            if failures >= statusRetries {
                guard LocalTorrentError.isConnectionInterruption(error) else { throw error }
                edit(id) {
                    $0.peers = 0; $0.seeders = 0; $0.attempted = nil
                    $0.checkingPieces = nil; $0.stalledSince = nil
                }
                peerDetails[id] = nil; censusAt[id] = nil
            }
            return nil
        }
    }

    /// Refreshes peers on the engine's cadence, alongside native status rates.
    ///
    /// One state escapes that cadence: no peers beside open sockets. Between
    /// censuses the count can only ratchet down, so a single poll that saw no
    /// sockets — a dropped status reply, the gap at a batch boundary, a swarm
    /// blinking out — pins the card at "0 peers" for the rest of the window
    /// while aria2 has already reconnected. Re-censusing then costs one
    /// loopback call at the poll cadence, and only while the count reads zero.
    func refreshCensus(_ id: UUID, gid: String, attempted: Int) async {
        // Only an active download has peers; anything else just cleared its stats.
        let now = Date()
        let blankWithSockets = attempted > 0 && job(id)?.peers == 0
        if let last = censusAt[id], now.timeIntervalSince(last) < censusInterval, !blankWithSockets { return }
        if attempted == 0 {
            edit(id) { $0.updatePeerCensus(.init()) }
            peerDetails[id] = nil; censusAt[id] = now
            await refreshNetworkCensus(id, gid: gid, now: now)
            return
        }
        if censusInterval <= 0 { peerDetails[id] = nil }
        let census: LocalTorrentPeerCensus
        do { census = try await engine.peerCensus(gid, attempted: attempted) }
        catch {
            guard !closed, gids[id] == gid, job(id)?.phase.active == true, !busy.contains(id) else { return }
            invalidatePeerRates(id)
            return
        }
        guard !closed, gids[id] == gid, job(id)?.phase.active == true, !busy.contains(id) else { return }
        censusAt[id] = now
        edit(id) { $0.updatePeerCensus(census) }
        peerDetails[id] = census.peers
        await refreshNetworkCensus(id, gid: gid, now: now)
    }

    private func refreshNetworkCensus(_ id: UUID, gid: String, now: Date) async {
        if let last = networkCensusAt[id], now.timeIntervalSince(last) < 30 { return }
        networkCensusAt[id] = now
        let network = try? await engine.networkDiagnostics(gid)
        guard !closed, gids[id] == gid, job(id)?.phase.active == true else { return }
        networkDetails[id] = network
    }

    /// A lost telemetry reply cannot prove that connected peers disappeared.
    /// Expire their rates and retry the census at the next status poll.
    func invalidatePeerRates(_ id: UUID) {
        peerDetails[id] = nil
        censusAt[id] = nil
    }

    /// Peers to show for a job. A census is only taken while the torrent is
    /// running, so any other phase would be showing the ghost of the last one.
    func connectedPeers(_ id: UUID) -> [LocalTorrentPeer] {
        guard let value = job(id), value.peers > 0, value.checkingPieces != true else { return [] }
        let phase = value.phase
        // `.uploading` beside a live torrent is a drain: finished files are on
        // their way to PikPak while the rest of the batch still downloads.
        guard phase == .downloading || phase == .metadata || (phase == .uploading && torrentIsLive(id)) else { return [] }
        return peerDetails[id] ?? []
    }

    /// Whether the engine still holds a torrent for this job. True throughout a
    /// drain; false once a finished batch has been handed to the uploader.
    func torrentIsLive(_ id: UUID) -> Bool { gids[id] != nil }

    /// Ask the resolver whether a proxy is answering for the trackers, off the
    /// main actor and no more than once a minute.
    private func refreshDNSState() {
        if let dnsProbedAt, Date().timeIntervalSince(dnsProbedAt) < 60 { return }
        dnsProbedAt = Date()
        let hosts = Aria2TorrentEngine.fallbackTrackers.compactMap { URL(string: $0)?.host }
        guard !hosts.isEmpty else { return }
        let target = TorrentDNSProbeTarget(self)
        let probe = dnsProbe
        Task.detached(priority: .utility) {
            let state = probe(hosts)
            await MainActor.run { target.model?.dnsState = state }
        }
    }

    func refresh() async {
        for value in jobs where value.phase.active || value.phase == .completed {
            launchPaddingCleanup(value.id)
        }
        if !engine.running { engineDidStop() }
        for value in jobs where value.automaticallyResume == true &&
            (value.phase == .paused || value.phase == .failed) &&
            value.retryAt.map({ $0 <= Date() }) == true && !busy.contains(value.id) {
            if let task = relayTasks[value.id], relayGenerations[value.id] == nil {
                await task.value
                relayTasks[value.id] = nil; relayUploaders[value.id] = nil
            }
            guard !closed, job(value.id)?.automaticallyResume == true else { continue }
            await resume(value.id, automatic: true)
        }
        portMapping = engine.portMapping
        refreshDNSState()
        if !peerDetails.isEmpty || !networkDetails.isEmpty {
            let running = Set(jobs.filter { $0.phase.active }.map(\.id))
            peerDetails = peerDetails.filter { running.contains($0.key) }
            networkDetails = networkDetails.filter { running.contains($0.key) }
        }
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
                guard let status = try await pollStatus(id, gid: gid, files: false) else {
                    guard !closed, gids[id] == gid, job(id)?.phase.active == true, !busy.contains(id) else { continue }
                    // The swarm and seed counts stand: nothing said they changed.
                    invalidatePeerRates(id)
                    edit(id) { $0.downloadSpeed = 0; $0.uploadSpeed = 0
                               if $0.phase != .metadata { $0.message = "Reconnecting to download status…" } }
                    continue
                }
                guard !closed, gids[id] == gid, job(id)?.phase.active == true, !busy.contains(id) else { continue }
                edit(id) { $0.updateTransferStats(status) }
                if status.state != "active" || status.connections == 0 { invalidatePeerRates(id) }
                if status.state == "active", !status.checkingPieces { await refreshCensus(id, gid: gid, attempted: status.connections) }
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
                        catch { edit(id) { $0.phase = .paused }; queueRecovery(id, message: error.localizedDescription) }
                    } else if ["error", "removed", "paused"].contains(status.state) { scheduleMetadataRetry(id) }
                    else if status.state == "waiting" {
                        edit(id) { $0.message = "Queued for a free torrent slot…" }
                    } else { edit(id) { $0.message = "Waiting for peers to share the file list. Will keep trying until paused or stopped…" } }
                } else {
                    let mapping = portMapping
                    edit(id) {
                        if status.completed > $0.completed { $0.retryAttempt = nil; $0.retryAt = nil }
                        $0.completed = status.completed; $0.total = status.total
                        $0.message = status.checkingPieces ? $0.checkingPiecesMessage :
                            status.state == "waiting" ? "Queued — up to three torrents run at once." : ($0.stallNote(portMapping: mapping, dns: dnsState) ?? "")
                        if status.state == "complete" { $0.phase = .completed; $0.completed = $0.total; $0.message = "Saved to this Mac. Seeding has stopped." }
                        else if status.state == "paused" { $0.phase = .paused }
                        else if status.state == "error" { $0.phase = .failed; $0.message = status.error }
                        else if status.state == "removed" { $0.phase = .paused }
                    }
                    if ["paused", "error", "removed"].contains(status.state) {
                        queueRecovery(id, message: status.error.isEmpty ? "Torrent transfer was interrupted." : status.error)
                    }
                    if job(id)?.phase.active == false { leases[id] = nil; saveOrReport() }
                }
            } catch {
                if !closed, gids[id] == gid, job(id)?.phase.active == true {
                    edit(id) { $0.clearTransferStats() }
                    if retryMetadataOnError { scheduleMetadataRetry(id) }
                    else if !engine.running { engineDidStop() }
                    else if value.phase == .metadata { edit(id) { $0.phase = .paused }; queueRecovery(id, message: error.localizedDescription) }
                    else { edit(id) { $0.message = "Reconnecting to download status…" } }
                }
            }
        }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true; polling?.cancel(); polling = nil
        saveRetryTask?.cancel(); saveRetryTask = nil
        restoredResumeIDs.removeAll()
        metadataRetryAt.removeAll()
        preparations.values.forEach { $0.cancel() }; preparations.removeAll()
        relayGenerations.removeAll()
        relayUploaders.values.forEach { $0.stop() }
        relayTasks.values.forEach { $0.cancel() }; relayTasks.removeAll()
        paddingCleanupUploaders.values.forEach { $0.stop() }
        paddingCleanupTasks.values.forEach { $0.cancel() }; paddingCleanupTasks.removeAll()
        for index in jobs.indices where jobs[index].phase.active {
            if jobs[index].automaticallyResume == nil { jobs[index].automaticallyResume = true }
            jobs[index].phase = .paused; jobs[index].clearTransferStats()
        }
        saveOrReport(); engine.stop(); gids.removeAll(); leases.removeAll(); peerDetails.removeAll()
    }
    func selectedTotal(_ files: [LocalTorrentFile]) throws -> UInt64 {
        try files.reduce(0) { total, file in
            let (value, overflow) = total.addingReportingOverflow(file.length)
            if overflow { throw LocalTorrentError.message("The torrent reports an invalid total size.") }
            return value
        }
    }
}
