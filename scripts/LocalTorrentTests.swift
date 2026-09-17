import AppKit
import CryptoKit
import SwiftUI

@MainActor final class TorrentFixtureEngine: LocalTorrentDriving {
    var running = false
    var states: [String: [String: Any]] = [:]
    var directories: [String: URL] = [:]
    var begun: [(String, URL, [Int])] = []
    var reselected: [(String, [Int])] = []
    var metadataRequests = 0
    var metadataFailures = 0
    var files = [("Examples/one.txt", UInt64(512)), ("Examples/two.txt", UInt64(1024))]
    var badManifest = false
    var ambiguousBegin = false
    var beginGate: CheckedContinuation<Void, Never>?
    var delayBegin = false
    /// Handshaked peers, when they differ from the sockets aria2 has open.
    var connectedPeers: Int?
    func start() async throws { running = true }
    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus {
        .init(connected: connectedPeers ?? attempted, attempted: attempted)
    }
    func addMagnet(_ magnet: String, directory: URL) async throws -> String {
        metadataRequests += 1
        if metadataFailures > 0 { metadataFailures -= 1; throw LocalTorrentError.message("Temporary metadata connection failure") }
        let id = UUID().uuidString
        states[id] = ["status":"active", "connections":"1"]; directories[id] = directory
        return id
    }
    func addTorrent(_ data: Data, directory: URL, selection: [Int]?) async throws -> String {
        let id = UUID().uuidString
        directories[id] = directory
        states[id] = ["status":"paused", "bittorrent":["info":["name":"Examples"]],
            "totalLength":"\(files.reduce(0) { $0 + $1.1 })", "files":files.enumerated().map { index, file in
                ["index":"\(index + 1)","path":badManifest ? "/tmp/outside-fixture" : directory.appendingPathComponent(file.0).path,"length":"\(file.1)"]
            }]
        return id
    }
    func status(_ id: String, files: Bool) async throws -> LocalTorrentStatus {
        guard let value = states[id] else { throw LocalTorrentError.message("Missing fixture torrent") }
        return .init(value)
    }
    func begin(_ id: String, directory: URL, selection: [Int]) async throws {
        begun.append((id, directory, selection)); states[id]?["status"] = "active"
        if delayBegin { await withCheckedContinuation { beginGate = $0 } }
        if ambiguousBegin { throw LocalTorrentError.message("Lost local RPC reply") }
    }
    func reselect(_ id: String, selection: [Int]) async throws { reselected.append((id, selection)) }
    /// Drive per-file `completedLength` on a fixture download.
    func setFileProgress(_ id: String, _ progress: [Int: UInt64]) {
        guard var entries = states[id]?["files"] as? [[String: Any]] else { return }
        for position in entries.indices {
            let index = Int(entries[position]["index"] as? String ?? "") ?? 0
            entries[position]["completedLength"] = "\(progress[index] ?? 0)"
        }
        states[id]?["files"] = entries
    }
    func pause(_ id: String) async throws { states[id]?["status"] = "paused" }
    func remove(_ id: String) async throws { states[id] = nil }
    func stop() { running = false }
    func finishMetadata(hash: String) throws {
        guard let id = states.first(where: { $0.value["files"] == nil })?.key, let folder = directories[id] else { preconditionFailure() }
        try Data("synthetic torrent metadata".utf8).write(to: folder.appendingPathComponent(hash + ".torrent"))
        states[id]?["status"] = "complete"
    }
}

@main struct LocalTorrentTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--ram-volume") { try await ramVolume(); return }
        if CommandLine.arguments.contains("--ui") { try launchUI(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--relay-fixture") { try await actualRelay(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return }
        if let index = CommandLine.arguments.firstIndex(of: "--fixture") {
            try await actualTransfer(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        try queueCompatibility()
        try perFileProgress()
        try drainLogic()
        try await engineReselect()
        try await streamingUploads()
        try await ramReclaim()
        try sourceAndPersistence()
        try await selectionAndRecovery()
        try await metadataAndCancellation()
        try await metadataStats()
        try trackerPrivacy()
        try stallDiagnosis()
        try await peerHonesty()
        try await metadataRetries()
        try await engineRestart()
        try ramBudgets()
        try await relayRecovery()
        try await relayControls()
        print("Local torrent tests passed: source validation, private state, selection before download, destination checks, ambiguous replies, pause/resume, restart and metadata cancellation.")
    }
    static func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudTorrentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor static func until(_ message: String, seconds: Double = 6, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw LocalTorrentError.message("Test timed out: " + message) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    static let hash = String(repeating: "ab", count: 20)
    static var magnet: String { "magnet:?xt=urn:btih:" + hash + "&dn=Examples" }
    static func sourceAndPersistence() throws {
        precondition(LocalTorrentSource.infoHash(magnet) == hash)
        precondition(LocalTorrentSource.infoHash("magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)) == String(repeating: "0", count: 40))
        precondition(LocalTorrentSource.infoHash("https://example.test/" + hash) == nil)
        precondition(LocalTorrentSource.infoHash("magnet:?xt=urn:btmh:1220" + hash) == nil)
        let selection = try LocalTorrentSource.selectionString([8,4,3,2,8,9,Int.max])
        precondition(selection == "2-4,8-9,\(Int.max)")
        do { _ = try LocalTorrentSource.selectionString([]); preconditionFailure("Empty selection accepted") } catch {}
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalTorrentStore(directory: root.appendingPathComponent("State"))
        var job = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        job.downloadSpeed = 2048; job.uploadSpeed = 128; job.peers = 4; job.seeders = 2; job.completed = 512
        try store.save([job]); let loaded = try store.load()[0]
        precondition(loaded.phase == .paused && loaded.downloadSpeed == 0 && loaded.uploadSpeed == 0 && loaded.peers == 0 && loaded.seeders == 0 && loaded.completed == 512)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory.appendingPathComponent("queue-v1.json").path)
        precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.directory)
        do { try LocalTorrentStore.protect(link); preconditionFailure("Symlink directory accepted") } catch {}
        try Data("broken queue".utf8).write(to: store.directory.appendingPathComponent("queue-v1.json"))
        do { _ = try store.load(); preconditionFailure("Corrupt queue discarded") } catch {}
    }
    @MainActor static func prepared(root: URL, engine: TorrentFixtureEngine) async throws -> (LocalTorrentModel, UUID) {
        let source = root.appendingPathComponent("example.torrent")
        try Data("fixture".utf8).write(to: source)
        let model = LocalTorrentModel(directory: root.appendingPathComponent("State"), engine: engine)
        let id = try model.add(torrent: source)
        try await until("file selection") { model.job(id)?.phase == .choosing || model.job(id)?.phase == .failed }
        return (model, id)
    }
    @MainActor static func selectionAndRecovery() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(); let (model, id) = try await prepared(root: root, engine: engine)
        defer { model.shutdown() }
        precondition(model.job(id)?.files.count == 2 && engine.begun.isEmpty, "Reading metadata must never start payload")
        await model.download(id, selected: [], to: root)
        precondition(engine.begun.isEmpty && model.job(id)?.destination == nil)
        await model.download(id, selected: [99], to: root)
        precondition(engine.begun.isEmpty && model.job(id)?.destination == nil)
        await model.download(id, selected: [2], to: root.appendingPathComponent("missing-disk"))
        precondition(engine.begun.isEmpty && model.job(id)?.destination == nil)
        engine.ambiguousBegin = true
        await model.download(id, selected: [2], to: root)
        precondition(engine.begun.count == 1 && engine.begun[0].2 == [2])
        precondition(model.job(id)?.phase == .downloading, "Ambiguous start must remain monitored")
        let destination = URL(fileURLWithPath: model.job(id)!.destination!)
        let partial = destination.appendingPathComponent("keep.partial")
        try Data("partial fixture".utf8).write(to: partial)
        await model.pause(id); precondition(model.job(id)?.phase == .paused)
        engine.ambiguousBegin = false; await model.resume(id)
        precondition(model.job(id)?.phase == .downloading && engine.begun.count == 2)
        await model.stop(id); precondition(model.job(id)?.phase == .stopped && FileManager.default.fileExists(atPath: partial.path))
        await model.resume(id); precondition(model.job(id)?.phase == .downloading)
        model.shutdown()
        let second = LocalTorrentModel(directory: model.store.directory, engine: TorrentFixtureEngine()); defer { second.shutdown() }
        precondition(second.job(id)?.phase == .paused && !second.engine.running && second.job(id)?.selected == [2])
        await second.remove(id)
        precondition(second.jobs.isEmpty && FileManager.default.fileExists(atPath: partial.path))
    }
    @MainActor static func metadataAndCancellation() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(), model = LocalTorrentModel(directory: root, engine: TorrentFixtureEngine())
        model.shutdown()
        let actual = LocalTorrentModel(directory: root.appendingPathComponent("Other"), engine: engine); defer { actual.shutdown() }
        let id = try actual.add(magnet: magnet)
        let duplicate = try actual.add(magnet: magnet + "&tr=http://127.0.0.1/announce")
        precondition(id == duplicate)
        try await until("magnet metadata request") { engine.metadataRequests == 1 && !actual.busy.contains(id) }
        precondition(engine.begun.isEmpty)
        engine.badManifest = true; try engine.finishMetadata(hash: hash)
        await actual.refresh()
        precondition(actual.job(id)?.phase == .failed, "Rejected manifest must not leave metadata stuck as active")
        engine.badManifest = false; await actual.resume(id)
        try await until("retry manifest") { actual.job(id)?.phase == .choosing }
        engine.delayBegin = true
        let start = Task { await actual.download(id, selected: [1], to: root) }
        try await until("begin gate") { engine.beginGate != nil }
        await actual.stop(id)
        engine.beginGate?.resume(); engine.beginGate = nil; await start.value
        try await until("stop requested during begin") { actual.job(id)?.phase == .stopped }
    }

    @MainActor static func engineRestart() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(); let (model, id) = try await prepared(root: root, engine: engine)
        defer { model.shutdown() }
        await model.download(id, selected: [1], to: root)
        engine.stop()
        let next = try model.add(magnet: magnet)
        try await until("new work after engine exit") { engine.metadataRequests == 1 && !model.busy.contains(next) }
        precondition(model.job(id)?.phase == .paused, "Restarting for another torrent must not strand existing jobs as active")
        await model.stop(next); await model.resume(id)
        precondition(model.job(id)?.phase == .downloading)
    }

    @MainActor static func metadataStats() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        let actual = LocalTorrentModel(directory: root.appendingPathComponent("Stats"), engine: engine)
        // Connected peers are normally censused every few seconds; this test
        // drives refresh() by hand, so every call must re-read the engine.
        actual.censusInterval = 0
        defer { actual.shutdown() }
        let id = try actual.add(magnet: magnet)
        try await until("metadata stats ready") { engine.metadataRequests == 1 && !actual.busy.contains(id) }
        func report(_ state: String = "active", peers: String = "7", seeds: String = "3", down: String = "4096", up: String = "512") {
            let gid = actual.gids[id]!
            engine.states[gid] = ["status":state, "connections":peers, "numSeeders":seeds, "downloadSpeed":down, "uploadSpeed":up]
        }
        func expect(_ peers: Int, _ seeds: Int, _ down: UInt64, _ up: UInt64) {
            let job = actual.job(id)!
            precondition(job.peers == peers && job.seeders == seeds && job.downloadSpeed == down && job.uploadSpeed == up,
                         "Live metadata statistics must track the engine, including zero values")
        }
        report(); await actual.refresh(); expect(7, 3, 4096, 512)
        precondition(actual.job(id)?.phase == .metadata && actual.job(id)?.files.isEmpty == true && engine.begun.isEmpty)
        report(peers: "0", seeds: "0", down: "0", up: "0")
        await actual.refresh(); expect(0, 0, 0, 0)
        report("waiting"); await actual.refresh(); expect(0, 0, 0, 0)
        report(); await actual.refresh(); expect(7, 3, 4096, 512)
        await actual.pause(id); expect(0, 0, 0, 0)
        precondition(actual.job(id)?.phase == .paused)
        await actual.resume(id)
        try await until("metadata stats resumed") { engine.metadataRequests == 2 && !actual.busy.contains(id) }
        report(); await actual.refresh(); expect(7, 3, 4096, 512)
        report("error")
        await actual.refresh(); expect(0, 0, 0, 0)
        precondition(actual.job(id)?.phase == .metadata && actual.metadataRetryAt[id] != nil)
        actual.metadataRetryAt[id] = Date().addingTimeInterval(-1)
        await actual.refresh()
        try await until("metadata stats retried") { engine.metadataRequests == 3 && !actual.busy.contains(id) }
        report(); await actual.refresh(); expect(7, 3, 4096, 512)
        try engine.finishMetadata(hash: hash)
        await actual.refresh(); expect(0, 0, 0, 0)
        precondition(actual.job(id)?.phase == .choosing && engine.begun.isEmpty)
        print("PASS: metadata peers, seeds and speeds refresh; queued, paused, retrying and completed metadata clear live stats.")
    }

    /// Fallback trackers may only reach torrents that allow outside announces.
    @MainActor static func trackerPrivacy() throws {
        func data(_ text: String) -> Data { Data(text.utf8) }
        precondition(TorrentMetadata.privacy(data("d4:infod7:privatei1e4:name3:abcee")) == .private)
        precondition(TorrentMetadata.privacy(data("d4:infod4:name3:abc7:privatei0eee")) == .shareable)
        precondition(TorrentMetadata.privacy(data("d4:infod4:name3:abcee")) == .shareable)
        // The trackerless torrents this fallback exists for carry only `info`.
        precondition(TorrentMetadata.privacy(data("d4:infod4:name3:abc12:piece lengthi16384eee")) == .shareable)
        // Nested containers must be stepped over, not mistaken for the flag.
        precondition(TorrentMetadata.privacy(data("d8:announce3:xyz4:infod5:filesld6:lengthi5eee7:privatei1eee")) == .private)
        // Anything unparseable withholds trackers rather than guessing.
        precondition(TorrentMetadata.privacy(data("d4:infod4:name3:ab")) == .unreadable)
        precondition(TorrentMetadata.privacy(data("not bencode")) == .unreadable)
        precondition(TorrentMetadata.privacy(Data()) == .unreadable)
        precondition(TorrentMetadata.privacy(data("d8:announce3:abce")) == .unreadable, "A torrent with no info dictionary is not shareable")
        precondition(Aria2TorrentEngine.fallbackTrackers.allSatisfy { $0.hasPrefix("udp://") || $0.hasPrefix("http") })
        print("PASS trackers: private torrents, unreadable metadata and info-only torrents are classified before any announce.")
    }

    /// A stalled download explains itself instead of reading "connecting" forever.
    static func stallDiagnosis() throws {
        var job = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        precondition(job.status == "Looking for peers")
        job.stalledSince = Date().addingTimeInterval(-30)
        precondition(job.stallNote(portMapping: .idle) == nil, "A brief quiet spell is not a stall")
        job.stalledSince = Date().addingTimeInterval(-600); job.attempted = 15
        let unreachable = job.stallNote(portMapping: .unsupported)
        precondition(unreachable?.contains("No peer has completed a connection in 10 minutes") == true, unreachable ?? "no note")
        precondition(unreachable?.contains("15 attempts are in flight") == true)
        precondition(unreachable?.contains("port mapping") == true)
        precondition(job.stallNote(portMapping: .failed("Router said no."))?.hasSuffix("Router said no.") == true)
        precondition(job.stallNote(portMapping: .mapped(tcp: 49_160, address: "203.0.113.5"))?.contains("reachable for incoming peers") == true)
        job.peers = 2
        precondition(job.status == "Connected — waiting for pieces")
        precondition(job.stallNote(portMapping: .idle)?.contains("Connected to 2 peers") == true)
        // A relay card must keep naming its batch whether or not it is stalled.
        var relayed = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        relayed.relay = TorrentRelayState(identity: UUID(), accountID: "a", credentialKind: .personalAccessToken, accountName: "n",
                                          parentID: "p", parentName: "P", rootName: "R", memoryBytes: TorrentRelayState.gib,
                                          batches: [[1], [2], [3]])
        precondition(relayed.relayProgressMessage(portMapping: .idle) == "Downloading batch 1 of 3 into RAM")
        relayed.stalledSince = Date().addingTimeInterval(-600)
        let stalled = relayed.relayProgressMessage(portMapping: .idle)
        precondition(stalled.hasPrefix("Downloading batch 1 of 3 into RAM — "), stalled)
        precondition(stalled.contains("No peer has completed a connection"), stalled)
        job.downloadSpeed = 1
        precondition(job.status == "Downloading" && job.stallNote(portMapping: .idle) == nil, "Progress ends the stall")
        print("PASS stalls: quiet downloads name the cause without losing the batch they belong to.")
    }

    /// aria2's `connections` counts sockets it opened, not peers that answered.
    @MainActor static func peerHonesty() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        let model = LocalTorrentModel(directory: root.appendingPathComponent("Peers"), engine: engine)
        model.censusInterval = 0
        defer { model.shutdown() }
        let id = try model.add(magnet: magnet)
        try await until("peer census ready") { engine.metadataRequests == 1 && !model.busy.contains(id) }
        func report(_ connections: String) {
            engine.states[model.gids[id]!] = ["status":"active", "connections":connections, "numSeeders":"0", "downloadSpeed":"0", "uploadSpeed":"0"]
        }
        engine.connectedPeers = 0
        report("13"); await model.refresh()
        precondition(model.job(id)?.peers == 0, "Connection attempts must not be reported as connected peers")
        precondition(model.job(id)?.attempted == 13)
        engine.connectedPeers = 3
        report("13"); await model.refresh()
        precondition(model.job(id)?.peers == 3 && model.job(id)?.attempted == 13)
        // A cached census must never outlive the sockets it was counted from.
        model.censusInterval = 600
        report("0"); await model.refresh()
        precondition(model.job(id)?.peers == 0, "Losing every socket must drop the peer count without waiting for a census")
        print("PASS peers: connected peers come from the peer list, and never outlive aria2's open sockets.")
    }

    @MainActor static func metadataRetries() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        let actual = LocalTorrentModel(directory: root.appendingPathComponent("Retries"), engine: engine)
        defer { actual.shutdown() }
        let id = try actual.add(magnet: magnet)
        try await until("persistent metadata wait") { engine.metadataRequests == 1 && !actual.busy.contains(id) }
        engine.states[actual.gids[id]!] = ["status":"active", "connections":"0"]
        await actual.refresh()
        precondition(actual.job(id)?.phase == .metadata && actual.metadataRetryAt[id] == nil && engine.metadataRequests == 1)

        engine.states[actual.gids[id]!]?["status"] = "error"
        await actual.refresh()
        precondition(actual.job(id)?.phase == .metadata && actual.metadataRetryAt[id] != nil)
        await actual.refresh()
        precondition(engine.metadataRequests == 1, "Metadata retries must wait instead of spinning")
        engine.metadataFailures = 1
        actual.metadataRetryAt[id] = Date().addingTimeInterval(-1)
        await actual.refresh()
        precondition(engine.metadataRequests == 2 && actual.job(id)?.phase == .metadata && actual.metadataRetryAt[id] != nil)
        actual.metadataRetryAt[id] = Date().addingTimeInterval(-1)
        await actual.refresh()
        precondition(engine.metadataRequests == 3 && actual.metadataRetryAt[id] == nil && engine.states.count == 1)

        engine.states[actual.gids[id]!]?["status"] = "error"
        await actual.refresh()
        await actual.pause(id)
        precondition(actual.job(id)?.phase == .paused && actual.metadataRetryAt[id] == nil && engine.states.isEmpty)
        await actual.refresh()
        precondition(engine.metadataRequests == 3, "Pausing must cancel an automatic metadata retry")

        await actual.resume(id)
        try await until("metadata wait resumed") { engine.metadataRequests == 4 && !actual.busy.contains(id) }
        engine.states.removeAll(); engine.stop()
        await actual.refresh()
        precondition(actual.job(id)?.phase == .metadata && actual.metadataRetryAt[id] != nil)
        actual.metadataRetryAt[id] = Date().addingTimeInterval(-1)
        await actual.refresh()
        precondition(engine.running && engine.metadataRequests == 5 && actual.metadataRetryAt[id] == nil)
        engine.states[actual.gids[id]!]?["status"] = "error"
        await actual.refresh()
        await actual.stop(id)
        await actual.refresh()
        precondition(actual.job(id)?.phase == .stopped && actual.metadataRetryAt[id] == nil && engine.states.isEmpty && engine.metadataRequests == 5)
        precondition(engine.begun.isEmpty, "Automatic metadata retries must never start file downloads")
        print("PASS: peer waiting persists; failed attempts and engine exit retry automatically; Pause and Stop cancel retries.")
    }

    @MainActor static func actualTransfer(_ fixture: URL) async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let root = fixture.deletingLastPathComponent()
        var options = ["enable-dht":"false","enable-dht6":"false","enable-peer-exchange":"false","bt-enable-lpd":"false",
                       "listen-port":"\(config["leecher_port"] as! Int)","max-overall-download-limit":"256K", "bt-tracker-interval":"2"]
        if let bootstrap = config["dht_bootstrap"] as? String {
            options["enable-dht"] = "true"
            options["dht-entry-point"] = bootstrap
            options["dht-listen-port"] = "\(config["dht_port"] as! Int)"
        }
        let executable = URL(fileURLWithPath: config["engine"] as! String)
        let state = root.appendingPathComponent("Queue")
        func makeModel() -> LocalTorrentModel {
            // Loopback fixtures must reach no network but their own.
            LocalTorrentModel(directory: state, engine: Aria2TorrentEngine(executable: executable, directory: state.appendingPathComponent("Engine"), extraOptions: options, trackers: [], mapsPorts: false))
        }
        let model = makeModel(); defer { model.shutdown() }
        precondition(!FileManager.default.fileExists(atPath: state.appendingPathComponent("Engine/dht.dat").path), "Discovery test must start without cached DHT nodes")
        let id = try model.add(magnet: config["magnet"] as! String)
        try await until("real magnet file list", seconds: 45) { model.job(id)?.phase != .metadata }
        guard let ready = model.job(id), ready.phase == .choosing else { throw LocalTorrentError.message(model.job(id)?.message ?? "Missing real job") }
        precondition(ready.files.count == 3 && ready.destination == nil)
        precondition(!FileManager.default.fileExists(atPath: state.appendingPathComponent(id.uuidString + "/FixtureFiles").path), "Metadata step created payload files")
        print("PASS: real peer metadata fetched; three files listed with no payload downloaded.")
        let output = root.appendingPathComponent("Downloads"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await model.download(id, selected: [1,3], to: output)
        guard model.job(id)?.phase == .downloading else { throw LocalTorrentError.message(model.error ?? "Real download did not start") }
        try await until("real piece transfer", seconds: 45) { (model.job(id)?.completed ?? 0) > 0 || model.job(id)?.phase == .failed }
        if model.job(id)?.phase == .failed { throw LocalTorrentError.message(model.job(id)!.message) }
        try await until("real peer and speed statistics", seconds: 15) {
            guard let job = model.job(id) else { return false }
            return job.peers > 0 && job.seeders > 0 && job.downloadSpeed > 0
        }
        print("PASS: real connected peer, seed and nonzero download speed reported.")
        await model.pause(id); precondition(model.job(id)?.phase == .paused)
        precondition(model.job(id)?.peers == 0 && model.job(id)?.seeders == 0 && model.job(id)?.downloadSpeed == 0 && model.job(id)?.uploadSpeed == 0)
        print("PASS: selected pieces received and transfer paused.")
        model.shutdown()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let restored = makeModel(); defer { restored.shutdown() }
        precondition(restored.job(id)?.phase == .paused && !restored.engine.running)
        await restored.resume(id)
        try await until("real resumed completion", seconds: 60) { [.completed,.failed].contains(restored.job(id)?.phase ?? .metadata) }
        guard let done = restored.job(id), done.phase == .completed, let path = done.destination else { throw LocalTorrentError.message(restored.job(id)?.message ?? "No completed torrent") }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("FixtureFiles")
        for name in ["keep.bin", "note.txt"] {
            let received = try Data(contentsOf: directory.appendingPathComponent(name))
            let original = try Data(contentsOf: root.appendingPathComponent("Seed/FixtureFiles/" + name))
            precondition(SHA256.hash(data: received) == SHA256.hash(data: original), "Resumed selected file mismatch")
        }
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("skip.bin").path), "Unselected file was retained")
        precondition(done.selected == [1,3])
        precondition(done.peers == 0 && done.seeders == 0 && done.downloadSpeed == 0 && done.uploadSpeed == 0)
        model.shutdown()
        let persisted = try LocalTorrentStore(directory: state).load().first { $0.id == id }
        precondition(persisted?.phase == .completed, "A repeated shutdown must not overwrite newer persisted progress")
        print("PASS: restart resumed partial pieces; selected files match SHA-256; unselected file removed; seeding stopped.")
    }

    @MainActor static func launchUI() throws {
        let root = try temporary(), engine = TorrentFixtureEngine()
        engine.files = (1...7105).map { ("Sample collection/Photo \($0).jpg", UInt64(150_000 + $0)) }
        let model = LocalTorrentModel(directory: root, engine: engine, ram: RelayFixtureRAM())
        let account = try DownloaderModel.finderAccountsFixture()
        let context = relayContext(identity: account.activeAccountID!, account: account.accountProfile!.sub, kind: .desktopOAuth)
        account.pikpakManagement.configure(context)
        account.pikpakManagement.fixture = { _ in
            try JSONSerialization.data(withJSONObject: ["account_id":context.accountID,"files":[["id":"fixture-folder","name":"Torrent Library","is_folder":true,"size":0,"parent_id":"","modified_time":"","trashed_time":""]],"next_page_token":""])
        }
        let cloud = RelayFixtureCloud(); cloud.blockUploads = true
        model.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(); let appMenu = NSMenu(); let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.mainMenu = menu
        let window = NSWindow(contentRect: .init(x: 100,y: 100,width: 1020,height: 780),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Local Torrent Fixture"; window.contentView = NSHostingView(rootView: LocalTorrentWorkspace(model: model, pikpak: account).padding(20))
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
        app.run(); model.shutdown()
    }
}


@MainActor final class RelayFixtureRAM: TorrentRAMDriving {
    var volumes: [UUID: TorrentRAMVolume] = [:]
    var released = 0
    var clears = 0
    func acquire(id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume {
        if let volume = volumes[id] { return volume }
        let mount = directory.appendingPathComponent("synthetic-ram")
        try LocalTorrentStore.protect(mount.appendingPathComponent("payload"))
        let volume = TorrentRAMVolume(device: "fixture", image: "ram://fixture", volumeDevice: "fixture", uuid: UUID().uuidString, mount: mount.path, owner: id, bytes: bytes)
        volumes[id] = volume; return volume
    }
    func validate(_ volume: TorrentRAMVolume) async throws { precondition(volumes[volume.owner] == volume) }
    func clear(_ volume: TorrentRAMVolume) async throws { try await validate(volume); clears += 1 }
    func release(_ volume: TorrentRAMVolume) async throws { volumes[volume.owner] = nil; released += 1 }
}
@MainActor final class RelayFixtureCloud {
    var receipts = Set<Int>()
    var uploads: [Int] = []
    var invocations = 0
    var blockUploads = false
    var failAfterFirst = false
}
@MainActor final class RelayFixtureUpload: TorrentRelayUploading {
    let cloud: RelayFixtureCloud
    var paused = false
    var stopped = false
    init(_ cloud: RelayFixtureCloud) { self.cloud = cloud }
    func pause(_ value: Bool) throws { paused = value }
    func stop() { stopped = true }
    func run(request: [String: Any], directory: URL, context: PikPakManagementContext, event: @escaping ([String: Any]) -> Void) async throws {
        cloud.invocations += 1
        let reconcile = request["reconcile_only"] as? Bool == true
        for source in request["files"] as! [[String: Any]] {
            let index = source["index"] as! Int
            if cloud.receipts.contains(index) { event(["event":"committed", "index":index]); continue }
            if reconcile { continue }
            event(["event":"hashing", "index":index])
            while cloud.blockUploads || paused { try Task.checkCancellation(); if stopped { throw CancellationError() }; try await Task.sleep(nanoseconds: 20_000_000) }
            try Task.checkCancellation()
            cloud.uploads.append(index); cloud.receipts.insert(index)
            event(["event":"committed", "index":index])
            if cloud.failAfterFirst { cloud.failAfterFirst = false; throw LocalTorrentError.message("Synthetic lost upload reply") }
        }
        event(["event":"finished"])
    }
}

extension LocalTorrentTests {
    static func ramBudgets() throws {
        let gib = TorrentRelayState.gib
        let hardware: [(UInt64, UInt64)] = [(8, 6), (16, 12), (24, 18), (32, 24), (64, 48), (128, 96)]
        for (installed, maximum) in hardware {
            let memory = installed * gib
            let options = TorrentRelayState.budgetOptions(physicalMemory: memory)
            precondition(TorrentRelayState.maximumBudget(physicalMemory: memory) == maximum * gib)
            precondition(options == Array(Set(options)).sorted() && options.first == gib && options.last == maximum * gib,
                         "RAM choices must grow with installed memory and include the supported maximum")
            for budget in options { try TorrentRelayState.validateBudget(budget, physicalMemory: memory) }
        }
        let memory = 64 * gib
        precondition(TorrentRelayState.budgetOptions(physicalMemory: memory) == [1, 2, 4, 8, 16, 24, 32, 48].map { UInt64($0) * gib })
        for invalid in [0, TorrentRelayState.minimumBudget - 512, gib + 1, 48 * gib + 512, memory] {
            do {
                try TorrentRelayState.validateBudget(invalid, physicalMemory: memory)
                preconditionFailure("Invalid RAM allocation accepted")
            } catch {}
        }
        let files = [LocalTorrentFile(index: 1, path: "one", length: 20 * gib),
                     LocalTorrentFile(index: 2, path: "two", length: 20 * gib)]
        do {
            _ = try TorrentRelayState.plan(files: files, budget: 16 * gib, pieceLength: 16_384, physicalMemory: memory)
            preconditionFailure("A file larger than its RAM buffer was accepted")
        } catch {}
        let smaller = try TorrentRelayState.plan(files: files, budget: 24 * gib, pieceLength: 16_384, physicalMemory: memory)
        let larger = try TorrentRelayState.plan(files: files, budget: 48 * gib, pieceLength: 16_384, physicalMemory: memory)
        precondition(smaller == [[1], [2]] && larger == [[1, 2]], "Larger RAM buffers must admit larger files and batches")
        print("PASS RAM budgets: hardware-scaled choices, 48 GB on a 64 GB Mac, allocation bounds and larger batches")
    }
    @MainActor static func relayContext(identity: UUID = UUID(), account: String = "account-a", kind: PikPakCredentialKind = .personalAccessToken) -> PikPakManagementContext {
        .init(identity: identity, accountID: account, engineURL: URL(fileURLWithPath: "/synthetic-helper"), environment: [:], credentialKind: kind)
    }
    @MainActor static func startRelay(root: URL, ram: RelayFixtureRAM, cloud: RelayFixtureCloud, files: [(String, UInt64)] = [("Examples/one",104_857_600),("Examples/two",104_857_600),("Examples/three",104_857_600)]) async throws -> (LocalTorrentModel, TorrentFixtureEngine, UUID, PikPakManagementContext) {
        let engine = TorrentFixtureEngine(); engine.files = files
        let (model,id) = try await prepared(root: root, engine: engine)
        model.ram = ram
        model.edit(id) { $0.pieceLength = 16_384 }
        let context = relayContext()
        model.relayContextProvider = { context }
        model.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        await model.downloadToPikPak(id, selected: Set(1...files.count), context: context, accountName: "Fixture account", parentID: "destination", parentName: "Destination", memoryBytes: 256 * 1024 * 1024)
        try await until("RAM download begins") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        return (model,engine,id,context)
    }
    @MainActor static func completeRelayBatch(_ model: LocalTorrentModel, engine: TorrentFixtureEngine, id: UUID) async throws {
        guard let gid = model.gids[id] else { preconditionFailure("missing RAM gid") }
        engine.states[gid]?["status"] = "complete"
        await model.refresh()
    }
    @MainActor static func relayRecovery() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try TorrentRelayState.plan(files: [.init(index:1,path:"too-big",length:UInt64.max)], budget: 256 * 1024 * 1024, pieceLength:16_384); preconditionFailure("oversize RAM file accepted") } catch {}
        let smallFiles = (1...7105).map { LocalTorrentFile(index:$0,path:"File\($0)",length:150_000) }
        let smallBatches = try TorrentRelayState.plan(files:smallFiles,budget:4 * TorrentRelayState.gib,pieceLength:16 * 1024 * 1024)
        precondition(smallBatches.count == 1, "adjacent small files must share boundary-piece allowance")
        let ram=RelayFixtureRAM(), cloud=RelayFixtureCloud()
        let (first,engine,id,context)=try await startRelay(root:root,ram:ram,cloud:cloud)
        precondition(first.job(id)?.relay?.batches == [[1,2],[3]])
        precondition(engine.begun.last?.2 == [1,2])
        precondition(engine.begun.last?.1.path.contains("synthetic-ram/payload") == true)
        cloud.failAfterFirst = true
        try await completeRelayBatch(first,engine:engine,id:id)
        try await until("upload failure is resumable") { first.job(id)?.phase == .failed && first.relayTasks[id] == nil }
        precondition(first.job(id)?.relay?.uploaded == [1] && cloud.uploads == [1])
        first.shutdown(); first.shutdown()
        // Cloud accepted another file, but its UI event was lost; a Mac restart
        // then discards all RAM. Only file 3 must be fetched again.
        cloud.receipts.insert(2); ram.volumes.removeAll()
        let nextEngine=TorrentFixtureEngine();nextEngine.files=engine.files
        let next=LocalTorrentModel(directory:first.store.directory,engine:nextEngine,ram:ram)
        next.relayContextProvider={context};next.relayUploaderFactory={RelayFixtureUpload(cloud)}
        await next.resume(id)
        try await until("recover cloud receipts before redownloading") { next.job(id)?.phase == .downloading && !next.busy.contains(id) }
        precondition(nextEngine.begun.last?.2 == [3])
        precondition(next.job(id)?.relay?.uploaded == [1,2])
        try await completeRelayBatch(next,engine:nextEngine,id:id)
        try await until("all batches uploaded") { next.job(id)?.phase == .completed }
        precondition(cloud.uploads == [1,3] && next.job(id)?.completed == next.job(id)?.total)
        precondition(ram.volumes.isEmpty && next.job(id)?.relay?.volume == nil)
        next.shutdown()
        print("PASS RAM relay: bounded batches, durable cloud receipts, lost RAM, skipped uploads and final memory release")
    }
    @MainActor static func relayControls() async throws {
        let root=try temporary();defer{try? FileManager.default.removeItem(at:root)}
        let ram=RelayFixtureRAM(),cloud=RelayFixtureCloud()
        let (model,engine,id,context)=try await startRelay(root:root,ram:ram,cloud:cloud,files:[("Example/one",1000),("Example/two",1000)])
        await model.pause(id);precondition(model.job(id)?.phase == .paused && ram.volumes.count == 1)
        await model.resume(id)
        try await until("torrent resumes using existing RAM") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        precondition(ram.released == 0)
        engine.ambiguousBegin = true
        await model.pause(id); await model.resume(id)
        try await until("lost unpause reply stays monitored") { model.job(id)?.phase == .downloading && model.relayTasks[id] == nil }
        precondition(model.gids[id] != nil)
        engine.ambiguousBegin = false
        cloud.blockUploads=true
        try await completeRelayBatch(model,engine:engine,id:id)
        try await until("upload starts") { model.relayUploaders[id] != nil && model.job(id)?.relay?.stage == "hashing" }
        await model.pause(id);precondition(model.job(id)?.phase == .paused)
        let calls=cloud.invocations
        cloud.blockUploads=false
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(cloud.uploads.isEmpty)
        // A credential-kind change is guarded just like an account change.
        model.relayContextProvider={relayContext(identity:context.identity,kind:.desktopOAuth)}
        await model.resume(id);precondition(model.job(id)?.phase == .paused && model.error != nil)
        model.relayContextProvider={context};await model.resume(id)
        try await until("paused uploader resumed") { model.job(id)?.phase == .completed }
        precondition(cloud.invocations == calls && cloud.uploads == [1,2])
        model.shutdown()
        let root2=try temporary();defer{try? FileManager.default.removeItem(at:root2)}
        let (retry,engine2,id2,context2)=try await startRelay(root:root2,ram:ram,cloud:RelayFixtureCloud())
        let original=retry.job(id2)?.relay?.volume?.uuid
        retry.relayContextProvider={relayContext(account:"other-account")}
        await retry.refresh()
        precondition(retry.job(id2)?.phase == .paused)
        retry.relayContextProvider={context2}
        await retry.restartRelay(id2)
        try await until("restart fetches into a new RAM volume") { retry.job(id2)?.phase == .downloading && !retry.busy.contains(id2) }
        precondition(retry.job(id2)?.relay?.volume?.uuid != original && engine2.begun.last?.2 == [1,2])
        await retry.stop(id2);precondition(retry.job(id2)?.phase == .stopped && ram.volumes.isEmpty)
        retry.shutdown()
        print("PASS RAM relay: download and upload pause/resume, account/login binding, restart unfinished work and stop cleanup")
    }
    @MainActor static func ramVolume() async throws {
        let root=try temporary(),driver=TorrentRAMDisk(),id=UUID()
        let volume=try await driver.acquire(id:id,bytes:256 * 1024 * 1024,directory:root)
        do {
            let file=volume.payload.appendingPathComponent("case.txt")
            let upper=volume.payload.appendingPathComponent("CASE.txt")
            try Data("lower".utf8).write(to:file);try Data("upper".utf8).write(to:upper)
            let lowerData = try Data(contentsOf:file), upperData = try Data(contentsOf:upper)
            precondition(lowerData != upperData)
            let restored=try await TorrentRAMDisk().acquire(id:id,bytes:256 * 1024 * 1024,directory:root)
            precondition(restored.uuid == volume.uuid)
            let sparse=volume.payload.appendingPathComponent("sparse.bin")
            FileManager.default.createFile(atPath:sparse.path,contents:nil)
            let handle=try FileHandle(forWritingTo:sparse);try handle.seek(toOffset:10 * 1024 * 1024 * 1024);try handle.write(contentsOf:Data("boundary".utf8));try handle.close()
            try await driver.clear(volume)
            let remaining = try FileManager.default.contentsOfDirectory(atPath:volume.payload.path)
            precondition(remaining.isEmpty)
            try await driver.release(volume)
            let permissions=try FileManager.default.attributesOfItem(atPath:volume.root.path)[.posixPermissions] as? NSNumber
            precondition(permissions?.intValue == 0o500)
            do { try Data("must not reach disk".utf8).write(to:volume.root.appendingPathComponent("test"));preconditionFailure("unmounted RAM path allowed disk writes") } catch {}
            try FileManager.default.removeItem(at:root)
            print("PASS real RAM disk: case-sensitive APFS, sparse boundary pieces, restart reuse, owned cleanup and disk-fallback prevention")
        } catch { try? await driver.release(volume);throw error }
    }
}

@MainActor final class RelayHashFixtureUpload: TorrentRelayUploading {
    let original: URL
    let ram: TorrentRAMDriving
    var hashes: [Int: SHA256.Digest] = [:]
    init(original: URL, ram: TorrentRAMDriving) { self.original = original; self.ram = ram }
    func pause(_ paused: Bool) throws {}
    func stop() {}
    func run(request: [String: Any], directory: URL, context: PikPakManagementContext, event: @escaping ([String: Any]) -> Void) async throws {
        if request["reconcile_only"] as? Bool == true { event(["event":"finished"]); return }
        let mount = URL(fileURLWithPath:request["ram_root"] as! String)
        let volume = try JSONDecoder().decode(TorrentRAMVolume.self, from:Data(contentsOf:directory.appendingPathComponent("ram-volume.json")))
        try await ram.validate(volume)
        for source in request["files"] as! [[String: Any]] {
            let path=source["path"] as! String,index=source["index"] as! Int
            let data=try Data(contentsOf:mount.appendingPathComponent(path))
            let reference=try Data(contentsOf:original.appendingPathComponent(path))
            let hash=SHA256.hash(data:data)
            precondition(hash == SHA256.hash(data:reference),"RAM torrent payload differs from the seed")
            hashes[index]=hash
            event(["event":"committed","index":index])
        }
        event(["event":"finished"])
    }
}
extension LocalTorrentTests {
    @MainActor static func actualRelay(_ fixture: URL) async throws {
        let config=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as! [String:Any]
        let root=fixture.deletingLastPathComponent(),state=root.appendingPathComponent("RAMQueue")
        let options=["enable-dht":"false","enable-dht6":"false","enable-peer-exchange":"false","bt-enable-lpd":"false","listen-port":"\(config["leecher_port"] as! Int)","max-overall-download-limit":"128K","bt-tracker-interval":"2"]
        let executable=URL(fileURLWithPath:config["engine"] as! String),ram=TorrentRAMDisk(),context=relayContext()
        let uploader=RelayHashFixtureUpload(original:root.appendingPathComponent("Seed"),ram:ram)
        func makeModel() -> LocalTorrentModel {
            let model=LocalTorrentModel(directory:state,engine:Aria2TorrentEngine(executable:executable,directory:state.appendingPathComponent("Engine"),extraOptions:options,trackers:[],mapsPorts:false),ram:ram)
            model.relayContextProvider={context};model.relayUploaderFactory={uploader}
            return model
        }
        let first=makeModel();let id=try first.add(magnet:config["magnet"] as! String)
        try await until("real RAM file list",seconds:45){first.job(id)?.phase == .choosing}
        await first.downloadToPikPak(id,selected:[1,3],context:context,accountName:"Synthetic PikPak",parentID:"fixture",parentName:"Fixture",memoryBytes:256 * 1024 * 1024)
        do {
            try await until("real RAM torrent pieces",seconds:50){ (first.job(id)?.relay?.batchDownloaded ?? 0) > 0 || first.job(id)?.phase == .failed }
            guard first.job(id)?.phase == .downloading else {throw LocalTorrentError.message(first.job(id)?.message ?? "RAM download failed")}
            await first.pause(id)
            let uuid=first.job(id)?.relay?.volume?.uuid
            precondition(first.job(id)?.phase == .paused)
            first.shutdown();try await Task.sleep(nanoseconds:1_500_000_000)
            let next=makeModel();await next.resume(id)
            try await until("RAM reuse after app restart",seconds:20){next.job(id)?.phase == .downloading || next.job(id)?.phase == .failed}
            precondition(next.job(id)?.relay?.volume?.uuid == uuid)
            try await until("verified RAM payload reaches upload sink",seconds:70){[.completed,.failed].contains(next.job(id)?.phase ?? .metadata)}
            guard next.job(id)?.phase == .completed else {await next.stop(id);throw LocalTorrentError.message(next.job(id)?.message ?? "RAM relay did not complete")}
            precondition(Set(uploader.hashes.keys) == [1,3])
            precondition(next.job(id)?.relay?.volume == nil)
            next.shutdown()
            print("PASS real peers → RAM → upload sink: selective SHA-256 verified files, partial-piece pause/restart/resume, RAM identity retained and released after commit")
        } catch {
            first.shutdown()
            if let volume=first.job(id)?.relay?.volume {try? await ram.release(volume)}
            throw error
        }
    }
}

extension LocalTorrentTests {
    /// A queue written by the build running on the user's Mac today.
    ///
    /// Every key here exists in the live `queue-v1.json`. Swift's synthesised
    /// `Codable` ignores property defaults, so a new non-optional field makes
    /// `load()` throw, `storageAvailable` go false and the whole queue vanish —
    /// taking a 440 GB in-flight transfer with it. No new key may be mandatory.
    static let legacyQueueJSON = """
    {"version":1,"jobs":[{
      "id":"CC45EE42-78DD-4722-82F4-FC1824E79F11",
      "name":"Fixture torrent",
      "phase":"downloading",
      "files":[{"index":1,"path":"a/one.bin","length":1048576},
               {"index":2,"path":"a/two.bin","length":2097152}],
      "selected":[1,2],
      "pieceLength":33554432,
      "completed":0,
      "total":3145728,
      "downloadSpeed":0,
      "uploadSpeed":0,
      "peers":0,
      "seeders":0,
      "message":"Downloading batch 1 of 11 into RAM",
      "createdAt":779500000,
      "relay":{
        "identity":"11111111-2222-3333-4444-555555555555",
        "accountID":"acct-1",
        "credentialKind":"personal-access-token",
        "accountName":"USER_Apple",
        "parentID":"parent-1",
        "parentName":"My PikPak",
        "rootName":"Fixture-CC45EE42",
        "memoryBytes":51539607552,
        "batches":[[1],[2]],
        "batch":0,
        "uploaded":[],
        "batchReady":false,
        "batchDownloaded":3970000000,
        "batchTotal":43720000000,
        "currentBytes":0,
        "stage":""
      }
    }]}
    """

    @MainActor static func queueCompatibility() throws {
        let saved = try JSONDecoder().decode(LocalTorrentStore.Saved.self, from: Data(legacyQueueJSON.utf8))
        precondition(saved.version == 1 && saved.jobs.count == 1, "legacy queue did not decode")
        let job = saved.jobs[0]
        precondition(job.name == "Fixture torrent")
        precondition(job.files.count == 2 && job.files[1].length == 2_097_152)
        precondition(job.selected == [1, 2])
        precondition(job.pieceLength == 33_554_432)
        precondition(job.attempted == nil, "absent optional keys must decode as nil")
        guard let relay = job.relay else { preconditionFailure("relay state was dropped") }
        precondition(relay.accountName == "USER_Apple")
        precondition(relay.credentialKind == .personalAccessToken)
        precondition(relay.memoryBytes == 51_539_607_552)
        precondition(relay.batches == [[1], [2]])
        precondition(relay.batch == 0 && relay.uploaded.isEmpty)
        precondition(relay.batchDownloaded == 3_970_000_000 && relay.batchTotal == 43_720_000_000)
        precondition(relay.volume == nil, "absent volume must decode as nil")

        // Saving from the new build and reloading must also keep every field.
        let round = try JSONDecoder().decode(LocalTorrentStore.Saved.self, from: JSONEncoder().encode(saved))
        precondition(round.jobs[0].relay?.batches == [[1], [2]])
        print("PASS queue compatibility: a queue saved by the shipping build still decodes, and round-trips")
    }
}

extension LocalTorrentTests {
    /// aria2 reports how much of each file it has verified. Reading it is what
    /// lets a finished file reach PikPak without waiting for its whole batch.
    @MainActor static func perFileProgress() throws {
        let status = LocalTorrentStatus([
            "status": "active", "totalLength": "3000", "completedLength": "1500",
            "files": [
                ["index": "1", "path": "/x/one.bin", "length": "1000", "completedLength": "1000"],
                ["index": "2", "path": "/x/two.bin", "length": "2000", "completedLength": "500"],
            ],
        ])
        precondition(status.files.count == 2)
        precondition(status.files[0].completedLength == 1000 && status.files[0].length == 1000)
        precondition(status.files[1].completedLength == 500)
        // A reply without the key must not drop the file.
        let sparse = LocalTorrentStatus([
            "status": "active",
            "files": [["index": "1", "path": "/x/one.bin", "length": "1000"]],
        ])
        precondition(sparse.files.count == 1 && sparse.files[0].completedLength == 0)
        print("PASS per-file progress: completedLength parsed, absent key defaults to zero")
    }
}

extension LocalTorrentTests {
    private static func drainFiles(_ lengths: [UInt64]) -> [LocalTorrentFile] {
        lengths.enumerated().map { .init(index: $0.offset + 1, path: "f\($0.offset).bin", length: $0.element) }
    }

    @MainActor static func drainLogic() throws {
        // Four 700-byte files against 1000-byte pieces: every piece is shared,
        // exactly the regime of the live torrent (22 MB files, 32 MiB pieces).
        let files = drainFiles([700, 700, 700, 700])
        let layout = TorrentRelayDrain.Layout(files: files, pieceLength: 1000)
        // file 1 = bytes 0..<700    -> piece 0       -> piece bytes 0..<1000
        // file 2 = bytes 700..<1400 -> pieces 0...1  -> piece bytes 0..<2000
        precondition(layout.pieceBytes(0) == 0..<1000)
        precondition(layout.pieceBytes(1) == 0..<2000)
        precondition(layout.touching(0..<1000) == 0..<2, "piece 0 carries files 1 and 2")

        // A lone committed file whose neighbour is still downloading must NOT
        // be removed: aria2 rewrites it when the shared piece lands. Measured
        // against aria2 1.37 during the design probe.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [1],
                                                 committed: [1], removed: []) == [])
        // Once the sharing neighbour is complete too, file 1 may go.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [1, 2],
                                                 committed: [1], removed: []) == [1])
        // Committed but not complete is never removable.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [2],
                                                 committed: [1], removed: []) == [])
        // Already removed files are not offered twice, and count as settled.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [2, 3],
                                                 committed: [2], removed: [1]) == [2])

        // A file larger than a piece owns its interior pieces outright.
        let big = TorrentRelayDrain.Layout(files: drainFiles([4000, 700]), pieceLength: 1000)
        precondition(big.pieceBytes(0) == 0..<4000)
        precondition(TorrentRelayDrain.removable(layout: big, complete: [1],
                                                 committed: [1], removed: []) == [1])

        // Zero-length files hold no bytes and never block a neighbour.
        let empty = TorrentRelayDrain.Layout(files: drainFiles([700, 0, 700]), pieceLength: 1000)
        precondition(TorrentRelayDrain.removable(layout: empty, complete: [1, 2, 3],
                                                 committed: [2], removed: []) == [2])

        // Flush policy.
        precondition(TorrentRelayDrain.shouldFlush(count: 0, bytes: 0, waiting: 9999, windowComplete: true) == false)
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 1, waiting: 0, windowComplete: true))
        precondition(TorrentRelayDrain.shouldFlush(count: 32, bytes: 1, waiting: 0, windowComplete: false))
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 256 * 1024 * 1024, waiting: 0, windowComplete: false))
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 1, waiting: 180, windowComplete: false))
        precondition(TorrentRelayDrain.shouldFlush(count: 31, bytes: 1, waiting: 179, windowComplete: false) == false)
        print("PASS drain logic: piece spans, shared-piece safety and flush policy")
    }
}

extension LocalTorrentTests {
    @MainActor static func engineReselect() async throws {
        let fixture = TorrentFixtureEngine()
        // Through the protocol: the relay only ever holds a LocalTorrentDriving.
        let engine: LocalTorrentDriving = fixture
        try await engine.start()
        let gid = try await engine.addTorrent(Data("x".utf8), directory: URL(fileURLWithPath: "/tmp"), selection: [1, 2])
        try await engine.reselect(gid, selection: [2])
        precondition(fixture.reselected.count == 1 && fixture.reselected[0].1 == [2])
        // Reselect must not resume a paused download; only `begin` unpauses.
        precondition(fixture.states[gid]?["status"] as? String == "paused", "reselect must not unpause")
        print("PASS engine reselect: selection changes without unpausing")
    }
}

extension LocalTorrentTests {
    /// Files must reach PikPak while their batch is still downloading. Before
    /// this, nothing uploaded until aria2 reported the whole batch complete —
    /// 66 hours away on the 440 GB torrent that prompted the change.
    @MainActor static func streamingUploads() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud)
        precondition(model.job(id)?.relay?.batches == [[1, 2], [3]])
        guard let gid = model.gids[id] else { preconditionFailure("missing RAM gid") }

        // aria2 finishes file 1 while file 2 is still arriving.
        engine.setFileProgress(gid, [1: 104_857_600, 2: 1_000, 3: 0])
        await model.refreshRelay(id)
        precondition(cloud.uploads.isEmpty, "one small file must not spawn an uploader immediately")

        // Having waited long enough, it goes on its own rather than waiting for
        // the rest of the batch.
        model.relayQueuedSince[id] = Date().addingTimeInterval(-TorrentRelayDrain.flushWait - 1)
        model.relayFileCensusAt[id] = nil
        await model.refreshRelay(id)
        try await until("file 1 saved mid-batch", seconds: 10) { model.job(id)?.relay?.uploaded.contains(1) == true }
        precondition(cloud.uploads == [1], "only the completed file should have been uploaded")
        precondition(engine.states[gid]?["status"] as? String != "complete", "the batch must still be downloading")
        precondition(model.job(id)?.phase == .downloading, "the download must resume after the upload")
        model.shutdown()
        print("PASS streaming uploads: a completed file reaches PikPak while its batch is still downloading")
    }
}

extension LocalTorrentTests {
    /// Uploaded files must give their memory back — but only once no file still
    /// being downloaded needs a piece that overlaps them. Deleting too early
    /// makes aria2 recreate the file and fetch it a second time.
    @MainActor static func ramReclaim() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        // 700-byte files against 1000-byte pieces: every piece is shared, the
        // regime of the real torrent (22 MB files, 32 MiB pieces).
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud,
            files: [("a/one.bin", 700), ("a/two.bin", 700), ("a/three.bin", 700)])
        model.edit(id) { $0.pieceLength = 1000 }
        guard let gid = model.gids[id], let volume = model.job(id)?.relay?.volume else { preconditionFailure("missing RAM job") }
        precondition(model.job(id)?.relay?.batches == [[1, 2, 3]])
        let payload = volume.payload.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for name in ["one.bin", "two.bin", "three.bin"] {
            try Data(repeating: 7, count: 700).write(to: payload.appendingPathComponent(name))
        }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: payload.appendingPathComponent(name).path) }

        // File 1 finishes and is uploaded, but file 2 shares its piece and is
        // still downloading, so nothing may be unlinked yet.
        engine.setFileProgress(gid, [1: 700, 2: 0, 3: 0])
        await model.refreshRelay(id)
        model.relayQueuedSince[id] = Date().addingTimeInterval(-TorrentRelayDrain.flushWait - 1)
        model.relayFileCensusAt[id] = nil
        await model.refreshRelay(id)
        try await until("file 1 uploaded", seconds: 10) { model.job(id)?.relay?.uploaded.contains(1) == true }
        model.relayFileCensusAt[id] = nil
        await model.refreshRelay(id)
        precondition(exists("one.bin"), "a file sharing a piece with an incomplete neighbour must stay in RAM")
        precondition(engine.reselected.isEmpty, "nothing may be deselected while its pieces are still wanted")

        // File 2 completes, so file 1's pieces are settled and it may go.
        engine.setFileProgress(gid, [1: 700, 2: 700, 3: 0])
        model.relayFileCensusAt[id] = nil
        await model.refreshRelay(id)
        try await until("file 1 unlinked", seconds: 10) { !exists("one.bin") }
        precondition(model.job(id)?.relay?.drained?.contains(1) == true)
        precondition(engine.reselected.last?.1 == [2, 3], "the drained file must be deselected before it is unlinked")
        precondition(exists("two.bin"), "a file that has not been uploaded must never be unlinked")
        model.shutdown()
        print("PASS RAM reclaim: shared-piece safety respected, drained file deselected then unlinked")
    }
}
