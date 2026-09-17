import Foundation

enum LocalTorrentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct LocalTorrentWireFile {
    let index: Int
    let path: String
    let length: UInt64
    /// Bytes aria2 has verified for this file. Reaching `length` means the file
    /// is whole on the volume and may be handed to the uploader, long before
    /// the rest of its batch arrives.
    let completedLength: UInt64
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
        error = String((value["errorMessage"] as? String ?? "").prefix(500))
        files = (value["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let index = Int(file["index"] as? String ?? ""), index > 0,
                  let path = file["path"] as? String, let length = UInt64(file["length"] as? String ?? "") else { return nil }
            return .init(index: index, path: path, length: length,
                         completedLength: UInt64(file["completedLength"] as? String ?? "") ?? 0)
        }
    }
}

/// Peers that finished the BitTorrent handshake.
///
/// aria2's `connections` counts sockets it has opened, including ones still in
/// SYN_SENT to a peer that will never answer, so it reads as a healthy swarm
/// while nothing is actually connected. Only `aria2.getPeers` knows the truth.
///
/// Seed counts are not included: aria2's `numSeeders` already counts only peers
/// that got far enough to send a bitfield, so it is honest and far cheaper.
struct LocalTorrentPeerCensus: Equatable {
    var connected = 0
    /// Sockets aria2 has open, from its `connections` field.
    var attempted = 0
}

@MainActor protocol LocalTorrentDriving: AnyObject {
    var running: Bool { get }
    var portMapping: TorrentPortMapState { get }
    func start() async throws
    func addMagnet(_ magnet: String, directory: URL) async throws -> String
    func addTorrent(_ data: Data, directory: URL, selection: [Int]?) async throws -> String
    func status(_ id: String, files: Bool) async throws -> LocalTorrentStatus
    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus
    func begin(_ id: String, directory: URL, selection: [Int]) async throws
    func reselect(_ id: String, selection: [Int]) async throws
    func pause(_ id: String) async throws
    func remove(_ id: String) async throws
    func stop()
}

extension LocalTorrentDriving {
    var portMapping: TorrentPortMapState { .idle }
    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus {
        .init(connected: attempted, attempted: attempted)
    }
}

/// One app-owned aria2 process. Its authenticated RPC interface is restricted to
/// loopback; PikPak tokens and shell proxy settings never reach this process.
@MainActor final class Aria2TorrentEngine: LocalTorrentDriving {
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
        "udp://exodus.desync.com:6969/announce"
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
    var running: Bool { child?.isRunning == true }

    init(executable: URL? = nil, directory: URL, extraOptions: [String: String] = [:],
         trackers: [String]? = nil, mapsPorts: Bool = true) {
        self.executable = executable ?? Bundle.main.resourceURL!.appendingPathComponent("TorrentEngine/aria2c")
        self.directory = directory; self.extraOptions = extraOptions
        self.trackers = trackers ?? Self.fallbackTrackers
        self.mapper = mapsPorts ? TorrentPortMapper() : nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
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
        let ports = reservedPorts()
        for _ in 0..<3 {
            try Task.checkCancellation()
            let port = Int.random(in: 49_152...65_000)
            secret = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            endpoint = URL(string: "http://127.0.0.1:\(port)/jsonrpc")!
            var options = [
                "enable-rpc":"true", "rpc-listen-all":"false", "rpc-allow-origin-all":"false",
                "rpc-listen-port":"\(port)", "rpc-secret":secret, "rpc-max-request-size":"64M",
                "max-concurrent-downloads":"3", "max-download-result":"2000", "seed-time":"0",
                "max-overall-upload-limit":"1M", "bt-max-peers":"100", "file-allocation":"none",
                "auto-save-interval":"5", "allow-overwrite":"false", "auto-file-renaming":"false",
                "check-integrity":"true", "bt-remove-unselected-file":"true", "pause-metadata":"true",
                "enable-dht":"true", "enable-dht6":"false", "bt-enable-lpd":"false",
                "dht-entry-point":"dht.transmissionbt.com:6881",
                "dht-file-path":directory.appendingPathComponent("dht.dat").path,
                // Single ports, not ranges: a NAT-PMP mapping has to name one.
                "listen-port":"\(ports.listen)", "dht-listen-port":"\(ports.dht)",
                "dir":directory.path, "no-netrc":"true", "all-proxy":"", "http-proxy":"", "https-proxy":"",
                "console-log-level":"error", "summary-interval":"0", "enable-color":"false",
                "stop-with-process":"\(ProcessInfo.processInfo.processIdentifier)"
            ]
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
    private func reservedPorts() -> (listen: UInt16, dht: UInt16) {
        let file = directory.appendingPathComponent("ports.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: UInt16].self, from: $0) } ?? [:]
        let listen = available(saved["listen"], in: 49_160...49_260)
        let dht = available(saved["dht"], in: 49_261...49_360)
        if saved["listen"] != listen || saved["dht"] != dht,
           let data = try? JSONEncoder().encode(["listen": listen, "dht": dht]) {
            try? LocalTorrentStore.write(data, to: file)
        }
        return (listen, dht)
    }

    /// Reuses the saved port when it is still free, otherwise finds another.
    private func available(_ saved: UInt16?, in range: ClosedRange<UInt16>) -> UInt16 {
        if let saved, range.contains(saved), bindable(saved) { return saved }
        for candidate in range.shuffled() where bindable(candidate) { return candidate }
        return saved ?? range.lowerBound
    }

    private func bindable(_ port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }
        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func beginMapping(_ ports: (listen: UInt16, dht: UInt16)) {
        guard let mapper else { return }
        mappingWatch?.cancel()
        mappingWatch = Task { [weak self] in
            await mapper.start(tcp: ports.listen, udp: ports.dht)
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

    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus {
        guard let peers = try await call("getPeers", [id]) as? [[String: Any]] else {
            throw LocalTorrentError.message("The torrent engine returned an unreadable peer list.")
        }
        return .init(connected: peers.count, attempted: attempted)
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
        return try gid(await call("addTorrent", [data.base64EncodedString(), [], options]))
    }

    func status(_ id: String, files: Bool = false) async throws -> LocalTorrentStatus {
        var keys = ["status","bittorrent","infoHash","totalLength", "pieceLength","completedLength","downloadSpeed","uploadSpeed","connections","numSeeders","errorMessage"]
        if files { keys.append("files") }
        guard let value = try await call("tellStatus", [id, keys]) as? [String: Any] else {
            throw LocalTorrentError.message("The torrent engine returned an unreadable status.")
        }
        return .init(value)
    }

    func begin(_ id: String, directory: URL, selection: [Int]) async throws {
        let indexes = try LocalTorrentSource.selectionString(selection)
        _ = try await call("changeOption", [id, ["dir":directory.path, "select-file":indexes, "bt-metadata-only":"false", "seed-time":"0"]])
        _ = try await call("unpause", [id])
    }
    /// Narrow a running download's file selection without resuming it.
    /// `begin` unpauses as well; a mid-flight deselection must not, or pausing
    /// a transfer would be undone by the next drained file.
    func reselect(_ id: String, selection: [Int]) async throws {
        let indexes = try LocalTorrentSource.selectionString(selection)
        _ = try await call("changeOption", [id, ["select-file": indexes]])
    }
    func pause(_ id: String) async throws { _ = try await call("forcePause", [id]) }
    func remove(_ id: String) async throws {
        let current = try await status(id, files: false)
        if ["complete", "error", "removed"].contains(current.state) { _ = try await call("removeDownloadResult", [id]) }
        else { _ = try await call("forceRemove", [id]) }
    }

    func stop() {
        startup?.cancel(); startup = nil
        mappingWatch?.cancel(); mappingWatch = nil
        if let mapper { Task { await mapper.stop() } }
        portMapping = .idle
        if let child, child.isRunning { child.interrupt() }
        child = nil; endpoint = nil; secret = ""
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
