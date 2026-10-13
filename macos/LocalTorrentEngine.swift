import Foundation
import Darwin

enum LocalTorrentError: LocalizedError, Equatable {
    case message(String)
    case ramDestinationMismatch
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .ramDestinationMismatch: return "The torrent engine is not targeting this transfer’s buffer. Stop and Resume to reconnect it."
        }
    }
    /// A lost loopback reply says nothing about whether aria2 still has peers.
    /// Keep retrying transport failures without pausing its live download.
    static func isConnectionInterruption(_ error: Error) -> Bool {
        guard let failure = error as? URLError else { return false }
        switch failure.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
            return true
        default: return false
        }
    }
}

struct LocalTorrentWireFile {
    let index: Int
    let path: String
    let length: UInt64
    /// Bytes aria2 has verified for this file. Reaching `length` means the file
    /// is whole on the volume and may be handed to the uploader, long before
    /// the rest of its batch arrives.
    let completedLength: UInt64
    var padding = false
}

struct LocalTorrentStatus {
    let state: String
    let name: String
    let infoHash: String
    let pieceLength: UInt64
    let total: UInt64
    let completed: UInt64
    let downloadSpeed: UInt64
    let uploadSpeed: UInt64
    let connections: Int
    let seeders: Int
    /// `verifiedLength` is present throughout hashing, including at zero.
    /// `verifyIntegrityPending` covers waiting for the hash-check slot.
    let checkingPieces: Bool
    /// Bytes re-read so far. Nil unless a check is actually running.
    let verifiedLength: UInt64?
    /// How far the check has read, against the whole torrent.
    ///
    /// `completedLength` cannot serve as the denominator: aria2 freezes it for
    /// the duration of a check, so the count overtakes it partway through and
    /// would report well over 100%.
    var checkingFraction: Double? {
        guard let verifiedLength, total > 0 else { return nil }
        return min(1, Double(verifiedLength) / Double(total))
    }
    let error: String
    let files: [LocalTorrentWireFile]

    init(_ value: [String: Any]) {
        func count(_ key: String) -> UInt64 { UInt64(value[key] as? String ?? "") ?? 0 }
        state = value["status"] as? String ?? "unknown"
        let torrent = value["bittorrent"] as? [String: Any]
        name = (torrent?["info"] as? [String: Any])?["name"] as? String ?? "Torrent"
        infoHash = value["infoHash"] as? String ?? ""
        pieceLength = count("pieceLength")
        total = count("totalLength"); completed = count("completedLength")
        downloadSpeed = count("downloadSpeed"); uploadSpeed = count("uploadSpeed")
        connections = Int(clamping: count("connections")); seeders = Int(clamping: count("numSeeders"))
        verifiedLength = (value["verifiedLength"] as? String).flatMap(UInt64.init)
        checkingPieces = verifiedLength != nil || value["verifyIntegrityPending"] as? String == "true"
        error = String((value["errorMessage"] as? String ?? "").prefix(500))
        files = (value["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let index = Int(file["index"] as? String ?? ""), index > 0,
                  let path = file["path"] as? String, let length = UInt64(file["length"] as? String ?? "") else { return nil }
            return .init(index: index, path: path, length: length,
                         completedLength: UInt64(file["completedLength"] as? String ?? "") ?? 0,
                         padding: file["padding"] as? String == "true")
        }
    }
}

/// Peers that finished the BitTorrent handshake.
///
/// aria2's `connections` counts sockets it has opened, including ones still in
/// SYN_SENT to a peer that will never answer. Upstream `getPeers` also includes
/// peers still negotiating; the bundled engine reports handshake completion
/// explicitly for the current connection.
///
/// Seed counts are not included: aria2's `numSeeders` already counts only peers
/// that got far enough to send a bitfield, so it is honest and far cheaper.
struct LocalTorrentPeerCensus: Equatable {
    var connected = 0
    /// Sockets aria2 has open, from its `connections` field.
    var attempted = 0
    /// The handshaked peers themselves, busiest first. Held in memory only.
    var peers: [LocalTorrentPeer] = []
}

/// One handshaked peer and what it is worth right now: what it is sending to
/// this Mac, and what this Mac is sending back to it.
///
/// Live details are separate from the saved queue. Public torrents may retain
/// validated connection endpoints in the private, expiring peer cache.
struct LocalTorrentPeer: Equatable {
    let address: String
    /// Bytes per second arriving from this peer.
    let downloadSpeed: UInt64
    /// Bytes per second this Mac is sending to this peer.
    let uploadSpeed: UInt64
    let seeder: Bool
    var transport: String? = nil
    var active: Bool { downloadSpeed > 0 || uploadSpeed > 0 }
}

/// Protocol counters only, kept in memory and never added to the saved queue.
/// Reading these counters does not inspect torrent contents or file progress.
struct LocalTorrentNetworkDiagnostics: Equatable {
    let dhtEnabled: Bool
    let dhtNodes: Int?
    let knownPeers: Int
    let trackerCount: Int
    let trackersResponding: Int
    let trackersFailed: Int
    let lastPeerError: String

    init(_ value: [String: Any], dht: [String: Any]) {
        dhtEnabled = dht["enabled"] as? Bool ?? false
        dhtNodes = dht["snapshotReady"] as? Bool == true ? dht["nodes"] as? Int : nil
        knownPeers = value["knownPeers"] as? Int ?? 0
        trackerCount = value["trackerCount"] as? Int ?? 0
        trackersResponding = value["trackersResponding"] as? Int ?? 0
        trackersFailed = value["trackersFailed"] as? Int ?? 0
        lastPeerError = String((value["lastPeerError"] as? String ?? "").prefix(200))
    }
}

@MainActor protocol LocalTorrentDriving: AnyObject {
    var running: Bool { get }
    var portMapping: TorrentPortMapState { get }
    /// Zero samples peer rates with every successful status poll. Legacy
    /// engines can keep a slower cadence when their replies carry bitfields.
    var peerCensusInterval: TimeInterval { get }
    func start() async throws
    func addMagnet(_ magnet: String, directory: URL) async throws -> String
    func addTorrent(_ data: Data, directory: URL, selection: [Int]?) async throws -> String
    func status(_ id: String, files: Bool) async throws -> LocalTorrentStatus
    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus
    func networkDiagnostics(_ id: String) async throws -> LocalTorrentNetworkDiagnostics?
    func begin(_ id: String, directory: URL, selection: [Int]) async throws
    func beginRelay(_ id: String, directory: URL, selection: [Int]) async throws
    func reselect(_ id: String, selection: [Int]) async throws
    func releaseFiles(_ id: String, directory: URL, indexes: [Int]) async throws -> Set<Int>
    func limitUpload(_ id: String, bytesPerSecond: UInt64) async throws
    func pause(_ id: String) async throws
    func remove(_ id: String) async throws
    func stop()
}

extension LocalTorrentDriving {
    var portMapping: TorrentPortMapState { .idle }
    var peerCensusInterval: TimeInterval { 30 }
    func releaseFiles(_ id: String, directory: URL, indexes: [Int]) async throws -> Set<Int> {
        throw LocalTorrentError.message("This torrent engine does not support live storage cleanup.")
    }
    func beginRelay(_ id: String, directory: URL, selection: [Int]) async throws {
        try await validateRelayPaths(id, directory: directory)
        try await begin(id, directory: directory, selection: selection)
    }
    /// Changing aria2's `dir` option does not relocate an existing torrent.
    /// Check its actual file paths before allowing a RAM relay to run.
    func validateRelayPaths(_ id: String, directory: URL) async throws {
        let current = try await status(id, files: true)
        let root = directory.standardizedFileURL.path + "/"
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var rootInfo = stat(), checked = Set<String>()
        let realDirectory = lstat(directory.path, &rootInfo) == 0 && (rootInfo.st_mode & S_IFMT) == S_IFDIR
        let confined = realDirectory && !current.files.isEmpty && current.files.allSatisfy { file in
            guard file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else { return false }
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            let prefix = path.hasPrefix(root) ? root : canonical
            guard path.hasPrefix(prefix), path.count > prefix.count else { return false }
            // resolvingSymlinksInPath leaves a path unchanged when its final
            // file does not exist yet. Check existing ancestors with lstat,
            // including dangling links, before aria2 creates any new files.
            var candidate = directory
            for part in path.dropFirst(prefix.count).split(separator: "/") {
                candidate.appendPathComponent(String(part))
                if checked.insert(candidate.path).inserted {
                    var info = stat()
                    if lstat(candidate.path, &info) == 0 {
                        if (info.st_mode & S_IFMT) == S_IFLNK { return false }
                    } else if errno != ENOENT { return false }
                }
            }
            return true
        }
        guard confined else {
            if !["paused", "complete", "error", "removed"].contains(current.state) { try await pauseAndWait(id) }
            throw LocalTorrentError.ramDestinationMismatch
        }
    }
    /// forcePause acknowledges the request before aria2 closes its files.
    /// Wait for that closure before removing anything from the RAM volume.
    func pauseAndWait(_ id: String) async throws {
        try await pause(id)
        for _ in 0..<200 {
            let current = try await status(id, files: false)
            if ["paused", "complete", "error", "removed"].contains(current.state) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LocalTorrentError.message("The torrent engine is still pausing. Resume to try again.")
    }
    func limitUpload(_ id: String, bytesPerSecond: UInt64) async throws {}
    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus {
        .init(connected: attempted, attempted: attempted)
    }
    func networkDiagnostics(_ id: String) async throws -> LocalTorrentNetworkDiagnostics? { nil }
}

/// One app-owned torrent process. Its authenticated RPC interface is restricted to
/// loopback; PikPak tokens and shell proxy settings never reach this process.
@MainActor class TorrentRPCEngine: LocalTorrentDriving {
    enum Backend { case aria2, libtorrent }
    private let backend: Backend
    /// Peer-seeking tuning, separate from per-launch ports and paths.
    ///
    /// Both engines read `bt-max-peers`, but they scope it differently: aria2
    /// applies it to each torrent, while the libtorrent helper maps it onto the
    /// session-wide connection limit that every transfer shares.
    ///
    /// `bt-request-peer-speed-limit` is aria2-only. aria2 stops looking for more
    /// peers once the download as a whole passes that rate — sensible when peers
    /// are plentiful, exactly wrong when a handful of seeders exist and every
    /// extra connection matters. Raising it past any real download rate keeps it
    /// hunting. libtorrent has no equivalent throttle, so the key is withheld
    /// there rather than written into a config that would silently ignore it and
    /// leave a later reader believing the knob still does something.
    ///
    /// Announce timing is deliberately absent: trackers publish a `min interval`
    /// and throttle clients that beat it, so each engine is left to obey every
    /// tracker rather than given one interval for a list we do not control.
    nonisolated static func peerTuning(_ backend: Backend) -> [String: String] {
        var tuning = ["bt-max-peers": "100"]
        if backend == .aria2 { tuning["bt-request-peer-speed-limit"] = "100M" }
        return tuning
    }

    /// Fallback announce URIs for torrents that carry none of their own.
    ///
    /// A trackerless torrent leaves DHT as the only way to find anyone, and DHT
    /// bootstrap can take tens of minutes or fail outright on networks that drop
    /// traffic to the public bootstrap nodes. These are withheld from private
    /// torrents, whose metadata names the only trackers they may be announced to.
    static let fallbackTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.stealth.si:80/announce",
        "udp://explodie.org:6969/announce",
        "udp://exodus.desync.com:6969/announce",
        // TCP announces, which stay up where UDP is throttled, filtered, or captured
        // by a fake-IP tunnel — the cases where a healthy swarm reads as empty.
        // Several of them, because one TCP tracker is a single point of failure, and
        // different trackers return different peers: the extra ones are what supply
        // seeder candidates when the first tracker's peers are all leechers.
        // Only hosts confirmed to answer an announce with live peers belong here.
        "https://tracker.opentrackr.org:443/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "http://t.overflow.biz:6969/announce",
        "http://tracker.mywaifu.best:6969/announce"
    ]

    let executable: URL
    let directory: URL
    private let extraOptions: [String: String]
    /// Empty in loopback tests, which must reach no network but their own.
    private let trackers: [String]
    private let mapper: TorrentPortMapper?
    private var child: Process?
    private var startup: Task<Void, Error>?
    private var endpoint: URL?
    private var secret = ""
    private let session: URLSession
    private(set) var portMapping: TorrentPortMapState = .idle
    private var mappingWatch: Task<Void, Never>?
    private var peerCacheAllowed = Set<String>()
    private var peerHashes: [String: String] = [:]
    private var peerRestoredAt: [String: Date] = [:]
    private var peerRestoreAttemptAt: [String: Date] = [:]
    private var peerCacheWrittenAt: [String: Date] = [:]
    private var cachedPeerAddresses: [String: Set<String>] = [:]
    private var peerCache: TorrentPeerCache { .init(directory: directory.appendingPathComponent("Peers", isDirectory: true)) }
    var running: Bool { child?.isRunning == true }
    var peerCensusInterval: TimeInterval { backend == .libtorrent ? 0 : 30 }

    init(executable: URL? = nil, directory: URL, extraOptions: [String: String] = [:],
         trackers: [String]? = nil, mapsPorts: Bool = true, backend: Backend) {
        self.backend = backend
        self.executable = executable ?? Bundle.main.resourceURL!.appendingPathComponent(
            backend == .libtorrent ? "TorrentEngine/mycloud-torrent" : "TorrentEngine/aria2c")
        self.directory = directory; self.extraOptions = extraOptions
        self.trackers = trackers ?? Self.fallbackTrackers
        self.mapper = mapsPorts ? TorrentPortMapper() : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    func start() async throws {
        if let startup { try await startup.value; return }
        if running { return }
        let task = Task { try await launch() }
        startup = task
        defer { startup = nil }
        try await task.value
    }

    private func launch() async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalTorrentError.message("The local torrent engine is missing. Reinstall this version of MyCloudDriver.")
        }
        try LocalTorrentStore.protect(directory)
        let ports = try reservedPorts()
        for _ in 0..<3 {
            try Task.checkCancellation()
            let port = Int.random(in: 49_152...65_000)
            secret = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
            var options = [
                "enable-rpc":"true", "rpc-listen-all":"false", "rpc-allow-origin-all":"false",
                "rpc-listen-port":"\(port)", "rpc-secret":secret, "rpc-max-request-size":"64M",
                "max-concurrent-downloads":"3", "max-download-result":"2000", "seed-time":"0",
                "max-overall-upload-limit":"4M", "file-allocation":"none",
                "auto-save-interval":"5", "allow-overwrite":"false", "auto-file-renaming":"false",
                "check-integrity":"true", "bt-remove-unselected-file":"true", "pause-metadata":"true",
                // A quiet swarm must remain eligible to discover new peers.
                "bt-stop-timeout":"0",
                // IPv6 DHT earns its keep on a CGNAT line, where no IPv4 port can be
                // reached from outside and the v6 swarm holds the only peers able to
                // open a connection inward. aria2 binds every v6 interface on its own,
                // but it keeps a separate routing table and needs its own entry point.
                "enable-dht":"true", "enable-dht6":"true", "bt-enable-lpd":"false",
                "dht-entry-point":"dht.transmissionbt.com:6881",
                "dht-entry-point6":"dht.transmissionbt.com:6881",
                "dht-file-path":directory.appendingPathComponent("dht.dat").path,
                "dht-file-path6":directory.appendingPathComponent("dht6.dat").path,
                // Single ports, not ranges: a NAT-PMP mapping has to name one.
                "listen-port":"\(ports.listen)",
                "dir":directory.path, "no-netrc":"true", "all-proxy":"", "http-proxy":"", "https-proxy":"",
                "console-log-level":"error", "summary-interval":"0", "enable-color":"false",
                "stop-with-process":"\(ProcessInfo.processInfo.processIdentifier)"
            ]
            // aria2 runs DHT on a socket of its own. The libtorrent helper serves
            // DHT from its listen port, so a second port here would only describe
            // a socket nothing binds — which is why the mapper below forwards the
            // listen port for that backend.
            if backend == .aria2 { options["dht-listen-port"] = "\(ports.dht)" }
            options.merge(Self.peerTuning(backend)) { _, new in new }
            options.merge(extraOptions) { _, new in new }
            // Test overrides cannot expose or deauthenticate the RPC endpoint.
            options["rpc-listen-all"] = "false"; options["rpc-allow-origin-all"] = "false"
            options["rpc-secret"] = secret; options["rpc-listen-port"] = "\(port)"
            let config = directory.appendingPathComponent("runtime.conf")
            try LocalTorrentStore.write(Data(options.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8), to: config)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--conf-path=\(config.path)"]
            process.environment = ["PATH":"/usr/bin:/bin", "LANG":"en_US.UTF-8"]
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); child = process
            for _ in 0..<40 {
                try Task.checkCancellation()
                if !process.isRunning { break }
                if (try? await call("getVersion", [])) != nil { beginMapping(ports); return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { process.terminate() }
            child = nil
        }
        throw LocalTorrentError.message("The local torrent engine could not start. Try again after closing other torrent tools.")
    }

    /// The BitTorrent and DHT ports, kept stable across launches so the router
    /// mapping and the peers that learned this Mac's address stay valid.
    private func reservedPorts() throws -> (listen: UInt16, dht: UInt16) {
        let file = directory.appendingPathComponent("ports.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: UInt16].self, from: $0) } ?? [:]
        let listen = try available(saved["listen"], in: 49_160...49_260, tcp: true, udp: backend == .libtorrent)
        let dht = try available(saved["dht"], in: 49_261...49_360, tcp: false, udp: true)
        if saved["listen"] != listen || saved["dht"] != dht,
           let data = try? JSONEncoder().encode(["listen": listen, "dht": dht]) {
            try? LocalTorrentStore.write(data, to: file)
        }
        return (listen, dht)
    }

    /// Reuses the saved port when it is still free, otherwise finds another.
    private func available(_ saved: UInt16?, in range: ClosedRange<UInt16>, tcp: Bool, udp: Bool) throws -> UInt16 {
        if let saved, range.contains(saved), Self.bindable(saved, tcp: tcp, udp: udp) { return saved }
        for candidate in range.shuffled() where Self.bindable(candidate, tcp: tcp, udp: udp) { return candidate }
        throw LocalTorrentError.message("No free torrent listen ports were found. Close another torrent tool and try again.")
    }

    static func bindable(_ port: UInt16, tcp: Bool = true, udp: Bool = true) -> Bool {
        var handles: [Int32] = []
        defer { for handle in handles { close(handle) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        for kind in (tcp ? [SOCK_STREAM] : []) + (udp ? [SOCK_DGRAM] : []) {
            let handle = socket(AF_INET, kind, 0)
            guard handle >= 0 else { return false }
            handles.append(handle)
            if kind == SOCK_STREAM {
                var reuse: Int32 = 1
                setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if !bound { return false }
        }
        return !handles.isEmpty
    }

    private func beginMapping(_ ports: (listen: UInt16, dht: UInt16)) {
        guard let mapper else { return }
        mappingWatch?.cancel()
        let udpPort = backend == .libtorrent ? ports.listen : ports.dht
        mappingWatch = Task { [weak self] in
            // libtorrent shares its listening port with µTP and DHT.
            await mapper.start(tcp: ports.listen, udp: udpPort)
            while !Task.isCancelled {
                let state = await mapper.state
                guard let self else { return }
                await MainActor.run { self.portMapping = state }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    /// Announce URIs to add to one download, unless the torrent forbids them.
    /// `data` is nil for a magnet, whose privacy is not yet knowable.
    private func trackerOption(_ data: Data?) -> [String: String] {
        guard !trackers.isEmpty else { return [:] }
        if let data, TorrentMetadata.privacy(data) != .shareable { return [:] }
        return ["bt-tracker": trackers.joined(separator: ",")]
    }

    /// What a PikPak relay may send to peers, per torrent.
    ///
    /// BitTorrent is reciprocal: most clients unchoke the peers that feed them,
    /// so a download giving nothing back is choked in return and runs slower.
    /// That argues for seeding generously — except on a relay, where peer
    /// upload and the PikPak upload share one uplink and only the PikPak
    /// upload returns RAM and lets the transfer advance. A relay therefore
    /// stays a polite participant rather than a generous one; a download to
    /// this Mac has no such competition and seeds under the shared ceiling.
    static let relayUploadLimit: UInt64 = 256 * 1024

    /// A swarm can hold thousands of peers. Only the ones doing work are worth
    /// carrying into the UI, so the list is ranked and cut here rather than
    /// grown without bound on every census.
    static let maximumPeersListed = 50

    /// libtorrent writes a peer off after three failed dials and revives it only
    /// when a tracker lists it again. Cached peers are therefore offered again
    /// on this cadence while a torrent runs, so a seeder that went offline is
    /// redialed once it returns rather than at the next start.
    static let peerRedialInterval: TimeInterval = 5 * 60

    /// Whether this torrent's cached peers are due to be offered to the engine.
    /// A failed offer is retried after five seconds: startup may not have
    /// created the engine's peer store yet.
    static func peerRestoreDue(restoredAt: Date?, attemptedAt: Date?, now: Date) -> Bool {
        guard now.timeIntervalSince(attemptedAt ?? .distantPast) >= 5 else { return false }
        return now.timeIntervalSince(restoredAt ?? .distantPast) >= peerRedialInterval
    }

    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus {
        guard let peers = try await call("getPeers", [id]) as? [[String: Any]] else {
            throw LocalTorrentError.message("The torrent engine returned an unreadable peer list.")
        }
        let connected = peers.filter(Self.peerIsConnected)
        let listed = Self.peerList(connected)
        if peerCacheAllowed.contains(id), let hash = peerHashes[id], !listed.isEmpty {
            let now = Date()
            let addresses = Set(listed.compactMap { TorrentPeerCache.Hint(peer: $0, now: now)?.address })
            if !addresses.isEmpty && (!addresses.isSubset(of: cachedPeerAddresses[id] ?? []) ||
                now.timeIntervalSince(peerCacheWrittenAt[id] ?? .distantPast) >= 60) {
                if (try? peerCache.record(hash, peers: listed, now: now)) != nil {
                    peerCacheWrittenAt[id] = now
                    cachedPeerAddresses[id] = Set(peerCache.load(hash, now: now).map(\.address))
                }
            }
        }
        return .init(connected: connected.count, attempted: attempted, peers: listed)
    }

    func networkDiagnostics(_ id: String) async throws -> LocalTorrentNetworkDiagnostics? {
        guard backend == .libtorrent,
              let value = try await call("getNetworkDiagnostics", []) as? [String: Any],
              let dht = value["dht"] as? [String: Any],
              let jobs = value["jobs"] as? [[String: Any]],
              let job = jobs.first(where: { $0["gid"] as? String == id }) else { return nil }
        return .init(job, dht: dht)
    }

    static func peerIsConnected(_ value: [String: Any]) -> Bool {
        // A peer ID can survive a disconnect inside aria2. Prefer the engine's
        // per-connection flag over interpreting an old ID as a new handshake.
        if let completed = value["handshakeCompleted"] as? String { return completed == "true" }
        if let completed = value["handshakeCompleted"] as? Bool { return completed }
        // Compatibility with older engines: IDs are 20 opaque bytes, percent
        // encoded by RPC, and start out all-zero before a peer replies.
        guard let identity = value["peerId"] as? String else { return false }
        let encoded = Array(identity.utf8)
        var cursor = 0, count = 0, nonzero = false
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while cursor < encoded.count {
            let byte: UInt8
            if encoded[cursor] == 37 {
                guard cursor + 2 < encoded.count, let high = hex(encoded[cursor + 1]),
                      let low = hex(encoded[cursor + 2]) else { return false }
                byte = high * 16 + low; cursor += 3
            } else { byte = encoded[cursor]; cursor += 1 }
            count += 1; nonzero = nonzero || byte != 0
            if count > 20 { return false }
        }
        return count == 20 && nonzero
    }

    static func peerList(_ values: [[String: Any]]) -> [LocalTorrentPeer] {
        let peers: [LocalTorrentPeer] = values.compactMap { value in
            guard peerIsConnected(value), let ip = (value["ip"] as? String), !ip.isEmpty else { return nil }
            func rate(_ key: String) -> UInt64 { UInt64(value[key] as? String ?? "") ?? 0 }
            // An IPv6 literal carries its own colons; bracket it so the port
            // that follows is still readable as a port.
            let host = ip.contains(":") ? "[\(ip)]" : ip
            let port = value["port"] as? String ?? ""
            return .init(address: port.isEmpty ? host : host + ":" + port,
                         downloadSpeed: rate("downloadSpeed"), uploadSpeed: rate("uploadSpeed"),
                         seeder: value["seeder"] as? String == "true",
                         transport: ["tcp", "utp"].contains(value["transport"] as? String ?? "")
                            ? value["transport"] as? String : nil)
        }
        func moving(_ peer: LocalTorrentPeer) -> UInt64 {
            let (sum, overflow) = peer.downloadSpeed.addingReportingOverflow(peer.uploadSpeed)
            return overflow ? .max : sum
        }
        return peers.sorted { left, right in
            moving(left) == moving(right) ? left.address < right.address : moving(left) > moving(right)
        }.prefix(maximumPeersListed).map { $0 }
    }

    func addMagnet(_ magnet: String, directory: URL) async throws -> String {
        guard LocalTorrentSource.infoHash(magnet) != nil else { throw LocalTorrentError.message("Enter a valid BitTorrent magnet link.") }
        // A magnet cannot declare itself private before its metadata arrives.
        // Private trackers hand out `.torrent` files rather than magnets, and
        // the download is re-added from metadata once it lands, which does
        // check the flag — so the fallback announce is limited to this stage.
        var options = ["dir":directory.path, "bt-metadata-only":"true", "bt-save-metadata":"true", "bt-stop-timeout":"0", "pause":"false"]
        options.merge(trackerOption(nil)) { _, new in new }
        return try gid(await call("addUri", [[magnet], options]))
    }

    func addTorrent(_ data: Data, directory: URL, selection: [Int]?) async throws -> String {
        guard !data.isEmpty, data.count <= LocalTorrentStore.maximumMetadataBytes else { throw LocalTorrentError.message("The torrent file is empty or exceeds 32 MB.") }
        var options = ["dir":directory.path, "pause":"true", "bt-metadata-only":"false", "seed-time":"0"]
        options.merge(trackerOption(data)) { _, new in new }
        if let selection { options["select-file"] = try LocalTorrentSource.selectionString(selection) }
        let id = try gid(await call("addTorrent", [data.base64EncodedString(), [], options]))
        if TorrentMetadata.privacy(data) == .shareable { peerCacheAllowed.insert(id) }
        return id
    }

    func status(_ id: String, files: Bool = false) async throws -> LocalTorrentStatus {
        var keys = ["status","bittorrent","infoHash","totalLength", "pieceLength","completedLength","downloadSpeed","uploadSpeed","connections","numSeeders","errorMessage","verifiedLength","verifyIntegrityPending"]
        if files { keys.append("files") }
        guard let value = try await call("tellStatus", [id, keys]) as? [String: Any] else {
            throw LocalTorrentError.message("The torrent engine returned an unreadable status.")
        }
        let snapshot = LocalTorrentStatus(value)
        if peerCacheAllowed.contains(id), TorrentPeerCache.validHash(snapshot.infoHash) {
            peerHashes[id] = snapshot.infoHash
            if snapshot.state == "paused" || snapshot.state == "waiting" || snapshot.checkingPieces {
                peerRestoredAt[id] = nil
            } else if snapshot.state == "active",
                      Self.peerRestoreDue(restoredAt: peerRestoredAt[id], attemptedAt: peerRestoreAttemptAt[id], now: Date()) {
                let now = Date()
                peerRestoreAttemptAt[id] = now; peerRestoredAt[id] = now
                let hints = peerCache.load(snapshot.infoHash)
                if !hints.isEmpty, (try? await call("addPeers", [id, hints.map(\.rpcValue)])) == nil {
                    peerRestoredAt[id] = nil // Startup may not have created the peer store yet.
                }
            }
        }
        return snapshot
    }

    func begin(_ id: String, directory: URL, selection: [Int]) async throws {
        let indexes = try LocalTorrentSource.selectionString(selection)
        _ = try await call("changeOption", [id, ["dir":directory.path, "select-file":indexes, "bt-metadata-only":"false", "seed-time":"0"]])
        _ = try await call("unpause", [id])
    }
    func beginRelay(_ id: String, directory: URL, selection: [Int]) async throws {
        let indexes = try LocalTorrentSource.selectionString(selection)
        try await validateRelayPaths(id, directory: directory)
        // Keep the GID available when the admitted files finish. The relay
        // removes it as soon as every chosen file is committed to PikPak.
        // aria2 requires a numeric seed-time; ten years is below its Int32
        // seconds limit and is never the transfer's completion condition.
        _ = try await call("changeOption", [id, ["dir":directory.path, "select-file":indexes,
            "bt-metadata-only":"false", "seed-time":"5256000", "seed-ratio":"0",
            "bt-remove-unselected-file":"false"]])
        _ = try await call("unpause", [id])
    }
    func limitUpload(_ id: String, bytesPerSecond: UInt64) async throws {
        _ = try await call("changeOption", [id, ["max-upload-limit":"\(bytesPerSecond)"]])
    }

    /// The bundled engine closes and unlinks only these verified files in its
    /// event loop. It preserves selection, completion bits and peer sockets,
    /// and stops advertising released pieces. No pause or recheck is needed.
    func releaseFiles(_ id: String, directory: URL, indexes: [Int]) async throws -> Set<Int> {
        guard !indexes.isEmpty, indexes.count <= 128, indexes.allSatisfy({ $0 > 0 }) else { return [] }
        guard let result = try await call("releaseFiles", [id, indexes, directory.path]) as? [Int],
              Set(result).isSubset(of: Set(indexes)) else {
            throw LocalTorrentError.message("The torrent engine returned an unreadable cleanup result.")
        }
        return Set(result)
    }

    /// Apply the filter after aria2 closes its old selection. Preserve a
    /// caller's pause; reopen only if the transfer was running at entry.
    func reselect(_ id: String, selection: [Int]) async throws {
        let indexes = try LocalTorrentSource.selectionString(selection)
        if backend == .libtorrent {
            _ = try await call("changeOption", [id, ["select-file": indexes]])
            return
        }
        let wasRunning = ["active", "waiting"].contains(try await status(id, files: false).state)
        if wasRunning { try await pauseAndWait(id) }
        _ = try await call("changeOption", [id, ["select-file": indexes]])
        if wasRunning { _ = try await call("unpause", [id]) }
    }
    func pause(_ id: String) async throws {
        _ = try await call("forcePause", [id])
        peerRestoredAt[id] = nil; peerRestoreAttemptAt[id] = nil
    }
    func remove(_ id: String) async throws {
        let current = try await status(id, files: false)
        if ["complete", "error", "removed"].contains(current.state) { _ = try await call("removeDownloadResult", [id]) }
        else { _ = try await call("forceRemove", [id]) }
        peerCacheAllowed.remove(id); peerHashes[id] = nil; peerRestoredAt[id] = nil
        peerRestoreAttemptAt[id] = nil; peerCacheWrittenAt[id] = nil; cachedPeerAddresses[id] = nil
    }

    func stop() {
        startup?.cancel(); startup = nil
        mappingWatch?.cancel(); mappingWatch = nil
        if let mapper { Task { await mapper.stop() } }
        portMapping = .idle
        if let child, child.isRunning { child.interrupt() }
        child = nil; endpoint = nil; secret = ""
        peerCacheAllowed.removeAll(); peerHashes.removeAll(); peerRestoredAt.removeAll()
        peerRestoreAttemptAt.removeAll(); peerCacheWrittenAt.removeAll(); cachedPeerAddresses.removeAll()
    }

    private func gid(_ result: Any) throws -> String {
        guard let id = result as? String, id.range(of: #"^[a-fA-F0-9]{16}$"#, options: .regularExpression) != nil else {
            throw LocalTorrentError.message("The torrent engine did not return a download identifier.")
        }
        return id
    }

    private func call(_ method: String, _ arguments: [Any]) async throws -> Any {
        guard let endpoint, running else { throw LocalTorrentError.message("The local torrent engine is stopped. Resume the download to reconnect.") }
        let requestID = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":requestID, "method":"aria2.\(method)", "params":["token:\(secret)"] + arguments])
        let (data, response) = try await session.data(for: request)
        guard data.count <= 64 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["id"] as? String == requestID else {
            throw LocalTorrentError.message("The local torrent engine returned an invalid reply.")
        }
        if let error = value["error"] as? [String: Any] {
            throw LocalTorrentError.message("Torrent engine: " + PikPakManagementError.safeMessage(error["message"] as? String ?? "The request failed."))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalTorrentError.message("The local torrent engine could not complete the request.")
        }
        guard let result = value["result"] else { throw LocalTorrentError.message("The torrent engine returned an incomplete reply.") }
        return result
    }
}

/// Kept available for migration fixtures and rollback compatibility.
@MainActor final class Aria2TorrentEngine: TorrentRPCEngine {
    init(executable: URL? = nil, directory: URL, extraOptions: [String: String] = [:],
         trackers: [String]? = nil, mapsPorts: Bool = true) {
        super.init(executable: executable, directory: directory, extraOptions: extraOptions,
                   trackers: trackers, mapsPorts: mapsPorts, backend: .aria2)
    }
}

@MainActor final class LibtorrentEngine: TorrentRPCEngine {
    init(executable: URL? = nil, directory: URL, extraOptions: [String: String] = [:],
         trackers: [String]? = nil, mapsPorts: Bool = true) {
        super.init(executable: executable, directory: directory, extraOptions: extraOptions,
                   trackers: trackers, mapsPorts: mapsPorts, backend: .libtorrent)
    }
}
