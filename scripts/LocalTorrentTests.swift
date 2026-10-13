import AppKit
import CryptoKit
import SwiftUI

@MainActor final class PaddingFixtureUpload: TorrentRelayUploading {
    var requests: [[Int]] = []
    var failures = 1
    var held = false
    var stops = 0
    func pause(_ paused: Bool) throws { held = paused }
    func stop() { stops += 1 }
    func run(request: [String: Any], directory: URL, context: PikPakManagementContext, event: @escaping ([String: Any]) -> Void) async throws {
        precondition(request["cleanup_padding"] as? Bool == true && request["reconcile_only"] as? Bool == true)
        precondition(directory.lastPathComponent == "PaddingCleanup")
        let indexes = (request["files"] as? [[String: Any]] ?? []).compactMap { $0["index"] as? Int }
        requests.append(indexes)
        while held { try await Task.sleep(nanoseconds: 10_000_000) }
        if failures > 0 { failures -= 1; throw URLError(.networkConnectionLost) }
        event(["event": "padding_cleaned", "checked": indexes, "removed": indexes])
    }
}

@MainActor final class TorrentFixtureEngine: LocalTorrentDriving {
    var running = false
    var states: [String: [String: Any]] = [:]
    var directories: [String: URL] = [:]
    var begun: [(String, URL, [Int])] = []
    var reselected: [(String, [Int])] = []
    var releases: [(String, [Int])] = []
    var releaseFailures = 0
    var metadataRequests = 0
    var metadataFailures = 0
    var files = [("Examples/one.txt", UInt64(512)), ("Examples/two.txt", UInt64(1024))]
    var padding = Set<Int>()
    var badManifest = false
    var ambiguousBegin = false
    var beginGate: CheckedContinuation<Void, Never>?
    var delayBegin = false
    /// Handshaked peers, when they differ from the sockets aria2 has open.
    var connectedPeers: Int?
    var limits: [String: UInt64] = [:]
    var peerDetail: [LocalTorrentPeer] = []
    var networkState: LocalTorrentNetworkDiagnostics?
    var networkChecks = 0
    var peerCensusInterval: TimeInterval = 30
    var peerChecks = 0
    var peerFailures = 0
    var statusChecks = 0
    var fileStatusChecks = 0
    var delayStatusFailure = false
    var statusFailureGate: CheckedContinuation<Void, Never>?
    /// Status replies to drop before answering again, as a busy local RPC does.
    var statusFailures = 0
    var statusFailureError: Error = LocalTorrentError.message("Lost local RPC reply")
    var pauses: [String] = []
    var checkingOnFileCensus = false
    func start() async throws { running = true }
    func peerCensus(_ id: String, attempted: Int) async throws -> LocalTorrentPeerCensus {
        peerChecks += 1
        if peerFailures > 0 { peerFailures -= 1; throw URLError(.networkConnectionLost) }
        return .init(connected: connectedPeers ?? attempted, attempted: attempted, peers: peerDetail)
    }
    func networkDiagnostics(_ id: String) async throws -> LocalTorrentNetworkDiagnostics? {
        networkChecks += 1; return networkState
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
                ["index":"\(index + 1)","path":badManifest ? "/tmp/outside-fixture" : directory.appendingPathComponent(file.0).path,"length":"\(file.1)","padding":padding.contains(index + 1) ? "true" : "false"]
            }]
        return id
    }
    func status(_ id: String, files: Bool) async throws -> LocalTorrentStatus {
        statusChecks += 1
        if files { fileStatusChecks += 1 }
        if delayStatusFailure {
            delayStatusFailure = false
            await withCheckedContinuation { statusFailureGate = $0 }
            throw URLError(.networkConnectionLost)
        }
        if statusFailures > 0 { statusFailures -= 1; throw statusFailureError }
        guard var value = states[id] else { throw LocalTorrentError.message("Missing fixture torrent") }
        if files, checkingOnFileCensus { value["verifiedLength"] = "0" }
        return .init(value)
    }
    func begin(_ id: String, directory: URL, selection: [Int]) async throws {
        begun.append((id, directory, selection)); states[id]?["status"] = "active"
        if delayBegin { await withCheckedContinuation { beginGate = $0 } }
        if ambiguousBegin { throw LocalTorrentError.message("Lost local RPC reply") }
    }
    func reselect(_ id: String, selection: [Int]) async throws { reselected.append((id, selection)) }
    func releaseFiles(_ id: String, directory: URL, indexes: [Int]) async throws -> Set<Int> {
        releases.append((id, indexes))
        if releaseFailures > 0 { releaseFailures -= 1; throw URLError(.networkConnectionLost) }
        precondition(directories[id] == directory)
        for index in indexes {
            if let file = try TorrentRelayStorage.file(files[index - 1].0, under: directory) {
                try FileManager.default.removeItem(at: file)
            }
        }
        return Set(indexes)
    }
    func limitUpload(_ id: String, bytesPerSecond: UInt64) async throws { limits[id] = bytesPerSecond }
    /// Drive per-file `completedLength` on a fixture download.
    func setFileProgress(_ id: String, _ progress: [Int: UInt64]) {
        guard var entries = states[id]?["files"] as? [[String: Any]] else { return }
        for position in entries.indices {
            let index = Int(entries[position]["index"] as? String ?? "") ?? 0
            entries[position]["completedLength"] = "\(progress[index] ?? 0)"
        }
        states[id]?["files"] = entries
    }
    func pause(_ id: String) async throws { pauses.append(id); states[id]?["status"] = "paused" }
    func remove(_ id: String) async throws { states[id] = nil }
    func stop() { running = false }
    func finishMetadata(hash: String) throws {
        guard let id = states.first(where: { $0.value["files"] == nil })?.key, let folder = directories[id] else { preconditionFailure() }
        try Data("synthetic torrent metadata".utf8).write(to: folder.appendingPathComponent(hash + ".torrent"))
        states[id]?["status"] = "complete"
    }
}

@main struct LocalTorrentTests {
    @MainActor static func fixtureEngine(executable: URL, directory: URL, extraOptions: [String: String],
                                         trackers: [String], mapsPorts: Bool) -> TorrentRPCEngine {
        if executable.lastPathComponent == "mycloud-torrent" {
            return LibtorrentEngine(executable: executable, directory: directory, extraOptions: extraOptions,
                                    trackers: trackers, mapsPorts: mapsPorts)
        }
        return Aria2TorrentEngine(executable: executable, directory: directory, extraOptions: extraOptions,
                                 trackers: trackers, mapsPorts: mapsPorts)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--ui-progress") || Bundle.main.object(forInfoDictionaryKey: "TorrentProgressFixture") as? Bool == true {
            let app = NSApplication.shared; app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1000, height: 560),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Synthetic Torrent Progress"
            window.contentView = NSHostingView(rootView: TorrentProgressFixtureView())
            window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); app.run(); return
        }
        if CommandLine.arguments.contains("--ram-volume") { try await ramVolume(); return }
        if CommandLine.arguments.contains("--peer-rate-tests") {
            try peerRatePolicies()
            try await peerRatesFollowStatusCadence()
            try await peerHonesty()
            try await networkDiagnosticsCadence()
            try await localStatusHiccup()
            try await relayDrainTelemetry()
            try await relaySpeeds()
            try await relayStatusHiccup()
            return
        }
        if CommandLine.arguments.contains("--ui") { try launchUI(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--reconnect-fixture") { try await actualPeerReconnect(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return }
        if let index = CommandLine.arguments.firstIndex(of: "--relay-fixture") { try await actualRelay(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return }
        if let index = CommandLine.arguments.firstIndex(of: "--grow-fixture") { try await actualSelectionGrowth(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return }
        if let index = CommandLine.arguments.firstIndex(of: "--fixture") {
            try await actualTransfer(URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        try queueCompatibility()
        try await paddingFiles()
        try await paddingCleanup()
        try await storageCopySafety()
        try await relayStorageMigration()
        try await eagerStorageCleanup()
        try await retainedStorageFiles()
        try await liveStorageLimit()
        try await storageLimitRestart()
        storageRetentionBudget()
        try await relayStorageCapacity()
        try await relayStorageRecovery()
        try await relayStorageFailures()
        try perFileProgress()
        try drainLogic()
        slidingAdmission()
        downloadEstimates()
        try await automaticTorrentResume()
        try await engineReselect()
        try await relayDestinationChecks()
        try await streamingUploads()
        try await stableRelayWindow()
        try await relayVerificationStability()
        try await ramReclaim()
        try await relayLoginSwitch()
        try await relayLiveLoginSwitch()
        try sourceAndPersistence()
        try await selectionAndRecovery()
        try await metadataAndCancellation()
        try await metadataStats()
        try trackerPrivacy()
        try stallDiagnosis()
        try fakeIPDiagnosis()
        try fakeIPProbe()
        try checkingProgress()
        try upnpDiscovery()
        try peerTuningDefaults()
        try peerRatePolicies()
        try await peerRatesFollowStatusCadence()
        try await peerHonesty()
        try await networkDiagnosticsCadence()
        peerListParsing()
        try peerCachePersistence()
        peerRedialCadence()
        try await localStatusHiccup()
        flushPressure()
        try await metadataRetries()
        try await engineRestart()
        try await relayEngineRestart()
        try ramBudgets()
        try await uploadLimits()
        try await ramBoundaryClears()
        try await relayRecovery()
        try await relayCloudOutage()
        try await relayOfflineFullBuffer()
        try await relayPauseDuringRecovery()
        try await relayControls()
        try await relaySpeeds()
        try await relayStatusHiccup()
        try await relayConnectionRecovery()
        try await relayDrainTelemetry()
        print("Local torrent tests passed: source validation, private state, selection before download, destination checks, ambiguous replies, pause/resume, restart and metadata cancellation.")
    }
    static func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudTorrentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    // Leave room for a routine 30-second census; explicit policy tests drive
    // refreshes directly instead of depending on wall-clock timer frequency.
    @MainActor static func until(_ message: String, seconds: Double = 40, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw LocalTorrentError.message("Test timed out: " + message) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    static let hash = String(repeating: "ab", count: 20)
    static var magnet: String { "magnet:?xt=urn:btih:" + hash + "&dn=Examples" }
    @MainActor static func paddingFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        engine.files = [("Examples/one", 4096), ("Examples/padding", 12288), ("Examples/two", 4096)]
        engine.padding = [2]
        let (model, id) = try await prepared(root: root, engine: engine)
        defer { model.shutdown() }
        var job = model.job(id)!
        precondition(job.files.count == 3 && job.payloadFiles.count == 2 && job.selected == [1,3] && job.total == 8192)
        let layout = TorrentRelayDrain.Layout(files: job.files, pieceLength: 16384)
        precondition(layout.pieceBytes(layout.slot(of: 3)!) == 16384..<32768, "Padding must remain in piece offsets")
        // A queue from the previous engine selected padding and may already
        // contain its cloud receipt. Migration must preserve that receipt.
        job.files[1].padding = nil; job.selected = [1,2,3]; job.total = 20480
        job.relay = TorrentRelayState(identity: UUID(), accountID: "fixture", credentialKind: .personalAccessToken,
            accountName: "Fixture", parentID: "destination", parentName: "Destination", rootName: "Generated",
            memoryBytes: 256 * 1024 * 1024, batches: [[1,2,3]])
        job.relay?.uploaded = [1,2]; job.relay?.selection = [1,2,3]; job.completed = 16384
        precondition(job.excludePaddingFiles([2]))
        precondition(job.selected == [1,3] && job.relay?.selection == [1,3] && job.total == 8192 && job.completed == 4096)
        precondition(job.relay?.uploaded == [1,2] && job.savedFileCount == 1)
        let restored = try JSONDecoder().decode(LocalTorrentJob.self, from: JSONEncoder().encode(job))
        precondition(restored.files[1].isPadding && restored.relay?.uploaded == [1,2])
        let mib: UInt64 = 1024 * 1024
        let padded = (0..<32).flatMap { i in [LocalTorrentFile(index: i * 2 + 1, path: "data\(i)", length: mib),
            LocalTorrentFile(index: i * 2 + 2, path: "padding\(i)", length: 31 * mib, padding: true)] }
        let payload = Set(padded.filter { !$0.isPadding }.map(\.index))
        let admitted = TorrentRelayDrain.admitStorage(files: padded, wanted: payload, uploaded: [], active: payload,
            progress: [:], available: 256 * mib, used: 0, limit: 256 * mib, pieceLength: 32 * mib, starting: false)
        precondition(Set(admitted.selection) == payload && !admitted.blockedOnSpace,
                     "Virtual padding must not multiply boundary reservations and shrink the window to one file")
        precondition(admitted.reservedBytes == 96 * mib + 32 * 4096)
        print("PASS padding files: hidden from selection/uploads, legacy receipts preserved, totals and piece offsets corrected")
    }
    @MainActor static func paddingCleanup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        engine.files = [("Examples/real", 4096), ("Examples/padding", 12288), ("Examples/padding-looking-real", 4096)]
        engine.padding = [2]
        let (model, id) = try await prepared(root: root, engine: engine)
        defer { model.shutdown() }
        model.polling?.cancel(); model.polling = nil
        let context = relayContext(), cloud = PaddingFixtureUpload()
        model.relayContextProvider = { context }
        model.paddingCleanupUploaderFactory = { cloud }
        let storage = try TorrentRelayStorage.create(in: root, owner: id)
        try LocalTorrentStore.protect(storage.payload.appendingPathComponent("Examples"))
        for name in engine.files.map(\.0) { try Data(repeating: 0x7a, count: 128).write(to: storage.payload.appendingPathComponent(name)) }
        var state = TorrentRelayState(identity: context.identity, accountID: context.accountID, credentialKind: context.credentialKind,
            accountName: "Fixture", parentID: "destination", parentName: "Destination", rootName: "Generated",
            memoryBytes: 256 * 1024 * 1024, batches: [[1,3]])
        state.storage = storage; state.selection = [1,3]; state.uploaded = [1]
        state.storageLimitBytes = UInt64.max
        model.edit(id) { $0.relay = state; $0.phase = .downloading }
        let gid = try await engine.addTorrent(Data(), directory: storage.payload, selection: [1,3])
        model.gids[id] = gid
        try await engine.begin(gid, directory: storage.payload, selection: [1,3])
        let pauses = engine.pauses.count
        engine.releaseFailures = 1
        await model.releaseRelayPadding(id, gid: gid, state: state)
        precondition(FileManager.default.fileExists(atPath: storage.payload.appendingPathComponent(engine.files[1].0).path))
        await model.releaseRelayPadding(id, gid: gid, state: state)
        precondition(engine.releases.map(\.1) == [[2], [2]], "Only metadata-flagged padding may be released")
        precondition(!FileManager.default.fileExists(atPath: storage.payload.appendingPathComponent(engine.files[1].0).path))
        for index in [0,2] {
            let generated = try Data(contentsOf: storage.payload.appendingPathComponent(engine.files[index].0))
            precondition(generated == Data(repeating: 0x7a, count: 128))
        }
        precondition(engine.pauses.count == pauses && model.job(id)?.relay?.uploaded == [1], "Padding does not need a cloud receipt or storage pressure")

        model.launchPaddingCleanup(id)
        try await until("padding cleanup failure recorded") { model.paddingCleanupTasks[id] == nil }
        precondition(cloud.requests == [[2]] && model.job(id)?.relay?.paddingCleanup?.retryAt != nil)
        model.launchPaddingCleanup(id)
        precondition(cloud.requests.count == 1, "Cleanup must back off without stopping the torrent")
        model.edit(id) { $0.relay?.paddingCleanup?.retryAt = .distantPast }
        model.launchPaddingCleanup(id)
        try await until("padding cleanup retry finished") { model.paddingCleanupTasks[id] == nil }
        precondition(cloud.requests == [[2],[2]] && model.job(id)?.relay?.paddingCleanup?.removed == [2])
        precondition(model.job(id)?.phase == .downloading && model.job(id)?.relay?.uploaded == [1])
        let saved = try model.store.load().first { $0.id == id }
        precondition(saved?.relay?.paddingCleanup?.checked == [2] && saved?.relay?.paddingCleanup?.failure == nil)
        model.launchPaddingCleanup(id)
        precondition(model.paddingCleanupTasks[id] == nil, "A restart must preserve cleanup acknowledgements")

        model.edit(id) { $0.relay?.paddingCleanup = nil }
        cloud.held = true; model.launchPaddingCleanup(id)
        try await until("padding cleanup begins before user pause") { cloud.requests.count == 3 }
        await model.pauseRelay(id)
        try await until("user pause cancels padding cleanup") { model.paddingCleanupTasks[id] == nil }
        model.launchPaddingCleanup(id)
        precondition(model.job(id)?.phase == .paused && model.paddingCleanupTasks[id] == nil && cloud.stops > 0)
        print("PASS padding cleanup: partial stubs released without storage pressure or cloud receipts; real files retained; cloud retries, durable acknowledgements and user pause")
    }

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
        let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("State"), engine: engine)
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
        let second = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: model.store.directory, engine: TorrentFixtureEngine()); defer { second.shutdown() }
        precondition(second.job(id)?.phase == .paused && !second.engine.running && second.job(id)?.selected == [2])
        await second.remove(id)
        precondition(second.jobs.isEmpty && FileManager.default.fileExists(atPath: partial.path))
    }
    @MainActor static func metadataAndCancellation() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(), model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root, engine: TorrentFixtureEngine())
        model.shutdown()
        let actual = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Other"), engine: engine); defer { actual.shutdown() }
        let id = try actual.add(magnet: magnet)
        let duplicate = try actual.add(magnet: magnet + "&tr=http://127.0.0.1/announce")
        precondition(id == duplicate)
        try await until("magnet metadata request") { engine.metadataRequests == 1 && !actual.busy.contains(id) }
        precondition(engine.begun.isEmpty)
        engine.badManifest = true; try engine.finishMetadata(hash: hash)
        await actual.refresh()
        precondition(actual.job(id)?.phase == .paused && actual.job(id)?.retryAt != nil,
                     "Rejected metadata must remain held for a validated retry")
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
        precondition(model.job(id)?.retryAt != nil)
        await model.stop(next)
        model.edit(id) { $0.retryAt = .distantPast }
        await model.refresh()
        precondition(model.job(id)?.phase == .downloading)
        engine.stop(); await model.refresh()
        await model.pause(id)
        model.edit(id) { $0.retryAt = .distantPast }
        await model.refresh()
        precondition(model.job(id)?.phase == .paused && model.job(id)?.automaticallyResume == false,
                     "Pausing a waiting retry must prevent engine restart")
    }

    @MainActor static func relayEngineRestart() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud)
        defer { model.shutdown() }
        let selected = model.job(id)?.selected, starts = engine.begun.count
        engine.stop(); await model.refresh()
        precondition(model.job(id)?.phase == .paused && model.job(id)?.retryAt != nil)
        model.edit(id) { $0.retryAt = .distantPast }
        await model.refresh()
        try await until("relay recovers from engine exit") {
            model.job(id)?.phase == .downloading && model.relayTasks[id] == nil
        }
        precondition(engine.begun.count == starts + 1 && model.job(id)?.selected == selected)
        precondition(model.job(id)?.relay?.volume != nil && model.job(id)?.automaticallyResume == true)
        print("PASS relay engine exit: automatic restart, receipt reconciliation and existing buffer preserved")
    }

    @MainActor static func metadataStats() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        let actual = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Stats"), engine: engine)
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
        // UDP announces die wherever UDP is blocked or captured by a fake-IP proxy;
        // an HTTP announce is the only one that still reaches a tracker there.
        // Several TCP announces, not one: UDP dies on filtered networks and behind a
        // fake-IP tunnel, and a single TCP tracker is a single point of failure for
        // peer discovery. Each entry here was confirmed to answer with live peers.
        let tcp = Aria2TorrentEngine.fallbackTrackers.filter { $0.hasPrefix("http") }
        precondition(tcp.count >= 3, "The tracker list needs several TCP announces, got \(tcp.count)")
        for expected in ["https://tracker.opentrackr.org:443/announce",
                         "http://t.overflow.biz:6969/announce",
                         "http://tracker.mywaifu.best:6969/announce"] {
            precondition(tcp.contains(expected), "missing verified tracker \(expected)")
        }
        // A host may repeat across transports on purpose — udp, http and https to the
        // same tracker are different failure modes. What must hold is that every entry
        // is a usable announce URL, since a malformed one silently announces nowhere.
        for entry in Aria2TorrentEngine.fallbackTrackers {
            guard let url = URL(string: entry), let host = url.host, !host.isEmpty else {
                preconditionFailure("unparseable tracker entry \(entry)")
            }
            precondition(url.path.hasSuffix("/announce"), "not an announce URL: \(entry)")
            precondition(["udp", "http", "https"].contains(url.scheme ?? ""), "bad scheme: \(entry)")
        }
        print("PASS trackers: private torrents, unreadable metadata and info-only torrents are classified before any announce.")
    }

    /// Virtual DNS identifies a proxy without asserting a network failure.
    static func fakeIPDiagnosis() throws {
        // 198.18.0.0/15 is RFC 2544 benchmark space, the pool Clash, mihomo,
        // sing-box and Surge hand out when they answer DNS themselves.
        precondition(TorrentFakeIP.isPlaceholder("198.18.0.54"))
        precondition(TorrentFakeIP.isPlaceholder("198.19.255.255"), "The pool is a /15, not a /16")
        precondition(!TorrentFakeIP.isPlaceholder("198.17.255.255"), "One below the pool is a real address")
        precondition(!TorrentFakeIP.isPlaceholder("198.20.0.0"), "One above the pool is a real address")
        precondition(!TorrentFakeIP.isPlaceholder("93.158.213.92"), "A real tracker address is not a placeholder")
        precondition(!TorrentFakeIP.isPlaceholder("not-an-address"))

        var job = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        job.stalledSince = Date().addingTimeInterval(-600)
        let hijacked = job.stallNote(portMapping: .unsupported, dns: .placeholder("198.18.0.54"))
        precondition(hijacked?.contains("198.18.0.54") == true, hijacked ?? "no note")
        precondition(hijacked?.lowercased().contains("proxy") == true, hijacked ?? "no note")
        precondition(hijacked?.contains("cannot leave") == false, "DNS does not prove a blocked route")
        precondition(hijacked?.contains("alone do not show") == true)
        // A proxy may use a different inbound route from the LAN router.
        precondition(hijacked?.contains("port mapping") == false, hijacked ?? "no note")
        // A clean resolver leaves the established advice exactly as it was.
        precondition(job.stallNote(portMapping: .unsupported, dns: .clean)?.contains("port mapping") == true)
        // Before the probe reports, nothing is claimed either way.
        precondition(job.stallNote(portMapping: .unsupported, dns: .unknown)?.contains("port mapping") == true)
        print("PASS fake-IP: DNS interception is named ahead of port advice.")
    }

    /// The probe reports interference only from answers it actually received,
    /// so an offline resolver is never mistaken for a healthy one.
    static func fakeIPProbe() throws {
        let hosts = ["tracker.example", "other.example"]
        precondition(TorrentFakeIP.probe(hosts) { _ in ["93.158.213.92"] } == .clean)
        precondition(TorrentFakeIP.probe(hosts) { _ in ["198.18.0.54"] } == .placeholder("198.18.0.54"))
        // Nothing resolved at all proves nothing either way.
        precondition(TorrentFakeIP.probe(hosts) { _ in [] } == .unknown)
        // A healthy first host must not clear an intercepted second one.
        let mixed = TorrentFakeIP.probe(hosts) { $0 == "other.example" ? ["198.19.7.7"] : ["1.1.1.1"] }
        precondition(mixed == .placeholder("198.19.7.7"), "\(mixed)")
        print("PASS fake-IP probe: interference is reported only from real answers.")
    }

    /// A hash check says how far it has read, so a long verify is not mistaken for
    /// a hang. The figure is aria2's `verifiedLength` against the whole torrent:
    /// `completedLength` is frozen for the duration of a check and cannot serve as
    /// a denominator — it is overtaken partway through.
    static func checkingProgress() throws {
        func status(_ extra: [String: Any]) -> LocalTorrentStatus {
            var value: [String: Any] = ["status": "active", "totalLength": "1000", "completedLength": "120"]
            value.merge(extra) { _, new in new }
            return LocalTorrentStatus(value)
        }
        precondition(status(["verifiedLength": "250"]).checkingFraction == 0.25)
        precondition(status(["verifyIntegrityPending": "true"]).checkingFraction == nil, "A queued check has no figure yet")
        precondition(status([:]).checkingFraction == nil)
        // Never print past 100%: this value already outran one plausible denominator.
        precondition(status(["verifiedLength": "5000"]).checkingFraction == 1)

        var job = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        job.updateTransferStats(status(["verifiedLength": "250"]))
        precondition(job.status == "Checking downloaded pieces — 25%", job.status)
        precondition(job.relayProgressMessage(portMapping: .idle, dns: .clean)
                     == "Checking downloaded pieces before continuing — 25%")
        // A check still waiting for its slot keeps the wording it has always had.
        job.updateTransferStats(status(["verifyIntegrityPending": "true"]))
        precondition(job.status == "Checking downloaded pieces", job.status)
        precondition(job.relayProgressMessage(portMapping: .idle, dns: .clean)
                     == "Checking downloaded pieces before continuing…")
        job.updateTransferStats(status(["verifiedLength": "1000"]))
        precondition(job.status == "Checking downloaded pieces — 100%", job.status)

        // Relay jobs refresh on their own path and set these fields by hand, so the
        // figure has to travel with the flag through one shared mutation. Without
        // it a relay card silently drops the percentage a storage card shows.
        var relayed = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        relayed.relay = TorrentRelayState(identity: UUID(), accountID: "a", credentialKind: .personalAccessToken,
                                          accountName: "n", parentID: "p", parentName: "P", rootName: "R",
                                          memoryBytes: TorrentRelayState.gib, batches: [[1]])
        relayed.applyCheckingState(status(["verifiedLength": "250"]))
        precondition(relayed.checkingPieces == true)
        precondition(relayed.checkingFraction == 0.25)
        precondition(relayed.relayProgressMessage(portMapping: .idle, dns: .clean)
                     == "Checking downloaded pieces before continuing — 25%",
                     relayed.relayProgressMessage(portMapping: .idle, dns: .clean))
        // Leaving the check clears both together.
        relayed.applyCheckingState(status([:]))
        precondition(relayed.checkingPieces == false && relayed.checkingFraction == nil)
        // Leaving the check behind clears the figure with it.
        job.updateTransferStats(status(["status": "active"]))
        precondition(job.status != "Checking downloaded pieces", job.status)
        print("PASS checking progress: a hash check reports its percentage against the whole torrent.")
    }

    /// UPnP is the other half of automatic port mapping. Routers that answer
    /// NAT-PMP and routers that answer UPnP are largely disjoint populations, and
    /// a client that speaks only one reports the other as "no port mapping".
    static func upnpDiscovery() throws {
        // Abridged from a real MiniUPnPd 20231115 gateway: the connection service
        // is two device levels down, and the useful one is not the first listed.
        let description = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
        <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
        <serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
        <controlURL>/ctl/L3F</controlURL></service></serviceList>
        <deviceList><device><deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
        <serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
        <controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList>
        <deviceList><device>
        <deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
        <serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>/ctl/IPConn</controlURL></service></serviceList>
        </device></deviceList></device></deviceList></device></root>
        """
        let location = URL(string: "http://192.168.31.1:5351/rootDesc.xml")!
        let found = TorrentUPnP.gateway(describedBy: Data(description.utf8), at: location)
        precondition(found?.control.absoluteString == "http://192.168.31.1:5351/ctl/IPConn", String(describing: found?.control))
        precondition(found?.service == "urn:schemas-upnp-org:service:WANIPConnection:1", String(describing: found?.service))
        // PPP gateways expose the same capability under a different service name.
        let ppp = description.replacingOccurrences(of: "WANIPConnection:1", with: "WANPPPConnection:1")
        precondition(TorrentUPnP.gateway(describedBy: Data(ppp.utf8), at: location)?.service.hasSuffix("WANPPPConnection:1") == true)
        // A gateway with no connection service is not usable, and must not be guessed at.
        let bare = "<root><device><serviceList><service>" +
                   "<serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>" +
                   "<controlURL>/ctl/L3F</controlURL></service></serviceList></device></root>"
        precondition(TorrentUPnP.gateway(describedBy: Data(bare.utf8), at: location) == nil)
        precondition(TorrentUPnP.gateway(describedBy: Data("not xml".utf8), at: location) == nil)

        // SOAP replies are read by element name; faults carry a code instead.
        let ok = Data("<s:Envelope><s:Body><u:GetExternalIPAddressResponse><NewExternalIPAddress>192.168.1.79</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>".utf8)
        precondition(TorrentUPnP.value("NewExternalIPAddress", in: ok) == "192.168.1.79")
        precondition(TorrentUPnP.value("NewLeaseDuration", in: ok) == nil)
        let fault = Data("<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>718</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>".utf8)
        precondition(TorrentUPnP.value("errorCode", in: fault) == "718")

        // Only a routable external address means peers can actually arrive.
        precondition(TorrentIPv4.isRoutable("203.0.113.5"))
        precondition(!TorrentIPv4.isRoutable("192.168.1.79"), "RFC1918")
        precondition(!TorrentIPv4.isRoutable("10.0.0.1"), "RFC1918")
        precondition(!TorrentIPv4.isRoutable("172.17.240.190"), "RFC1918 - the CMCC gateway's own WAN")
        precondition(TorrentIPv4.isRoutable("172.32.0.1"), "Just above the 172.16/12 block")
        precondition(!TorrentIPv4.isRoutable("100.64.0.1"), "Carrier-grade NAT")
        precondition(TorrentIPv4.isRoutable("100.128.0.1"), "Just above the CGNAT block")
        precondition(!TorrentIPv4.isRoutable("169.254.1.1"), "Link-local")
        precondition(!TorrentIPv4.isRoutable("nonsense"))

        // A mapping onto a private WAN must not be reported as reachability.
        var job = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        job.stalledSince = Date().addingTimeInterval(-600)
        let behind = job.stallNote(portMapping: .mapped(tcp: 49_189, address: "192.168.1.79"), dns: .clean)
        precondition(behind?.contains("192.168.1.79") == true, behind ?? "no note")
        precondition(behind?.contains("reachable for incoming peers") == false, behind ?? "no note")
        let reachable = job.stallNote(portMapping: .mapped(tcp: 49_189, address: "203.0.113.5"), dns: .clean)
        precondition(reachable?.contains("incoming port mapping on port") == true, reachable ?? "no note")
        precondition(reachable?.contains("external reachability has not been verified") == true)
        print("PASS UPnP: gateways are discovered, faults read, and an unroutable mapping is not called reachable.")
    }

    /// Engine tuning for swarms that are starved rather than fast.
    static func peerTuningDefaults() throws {
        let tuning = Aria2TorrentEngine.peerTuning(.aria2)
        // aria2 stops reaching for more peers once the download exceeds this rate.
        // Its 50K default is backwards for a thin swarm — the case where hunting
        // matters most — and lifting it was measured to double throughput from a
        // single seeder. Set high enough that it never calls a download fast enough.
        precondition(tuning["bt-request-peer-speed-limit"] == "100M", "got \(tuning["bt-request-peer-speed-limit"] ?? "nil")")
        // libtorrent has no such throttle. Writing the key anyway would leave a
        // dead setting in its config for a later reader to trust and retune.
        let native = Aria2TorrentEngine.peerTuning(.libtorrent)
        precondition(native["bt-request-peer-speed-limit"] == nil,
                     "libtorrent must not be given an aria2-only peer-speed throttle")
        precondition(native["bt-max-peers"] == "100", "got \(native["bt-max-peers"] ?? "nil")")
        // Trackers publish a `min interval` and ignore or throttle clients that
        // announce more often — opentrackr asks 1820s. Re-announcing sooner looks
        // like a way to find peers in a thin swarm and instead loses the tracker
        // altogether. Unset means aria2 obeys whatever each tracker asks, which is
        // the only safe default across a list we do not control.
        if let interval = tuning["bt-tracker-interval"], let seconds = Int(interval) {
            precondition(seconds == 0 || seconds >= 1800,
                         "bt-tracker-interval=\(interval) breaches a tracker's min interval")
        }
        precondition(tuning["bt-max-peers"] == "100")
        // Tuning must not smuggle in per-launch state: these are constants, and a
        // path or port here would leak one run's values into the next.
        for (key, value) in tuning {
            precondition(!value.contains("/"), "\(key) looks like a path: \(value)")
            precondition(!key.hasPrefix("rpc-"), "RPC settings are not tuning: \(key)")
        }
        print("PASS peer tuning: aria2 keeps hunting on a thin swarm instead of settling for 50K.")
    }

    /// A stalled download explains itself instead of reading "connecting" forever.
    static func stallDiagnosis() throws {
        var job = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        precondition(job.status == "Looking for peers")
        job.stalledSince = Date().addingTimeInterval(-30)
        precondition(job.stallNote(portMapping: .idle, dns: .clean) == nil, "A brief quiet spell is not a stall")
        job.stalledSince = Date().addingTimeInterval(-600); job.attempted = 15
        let unreachable = job.stallNote(portMapping: .unsupported, dns: .clean)
        precondition(unreachable?.contains("No peer has completed a connection in 10 minutes") == true, unreachable ?? "no note")
        precondition(unreachable?.contains("15 attempts are in flight") == true)
        precondition(unreachable?.contains("port mapping") == true)
        precondition(job.stallNote(portMapping: .failed("Router said no."), dns: .clean)?.hasSuffix("Router said no.") == true)
        precondition(job.stallNote(portMapping: .mapped(tcp: 49_160, address: "203.0.113.5"), dns: .clean)?.contains("incoming port mapping on port") == true)
        precondition(unreachable?.contains("peers behind NAT cannot answer") == false)
        job.peers = 2
        precondition(job.status == "Connected — waiting for pieces")
        precondition(job.stallNote(portMapping: .idle, dns: .clean)?.contains("Connected to 2 peers") == true)
        // A relay card must keep naming its batch whether or not it is stalled.
        var relayed = LocalTorrentJob(id: UUID(), name: "Example", phase: .downloading)
        relayed.relay = TorrentRelayState(identity: UUID(), accountID: "a", credentialKind: .personalAccessToken, accountName: "n",
                                          parentID: "p", parentName: "P", rootName: "R", memoryBytes: TorrentRelayState.gib,
                                          batches: [[1], [2], [3]])
        precondition(relayed.relayProgressMessage(portMapping: .idle, dns: .clean) == "Downloading 0 files into RAM")
        relayed.stalledSince = Date().addingTimeInterval(-600)
        let stalled = relayed.relayProgressMessage(portMapping: .idle, dns: .clean)
        precondition(stalled.hasPrefix("Downloading 0 files into RAM — "), stalled)
        precondition(stalled.contains("No peer has completed a connection"), stalled)
        job.downloadSpeed = 1
        precondition(job.status == "Downloading" && job.stallNote(portMapping: .idle, dns: .clean) == nil, "Progress ends the stall")
        print("PASS stalls: quiet downloads name the cause without losing the batch they belong to.")
    }

    /// Peer payload cost controls cadence without launching either backend.
    @MainActor static func peerRatePolicies() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let native = LibtorrentEngine(executable: executable, directory: root.appendingPathComponent("NativeEngine"),
                                      trackers: [], mapsPorts: false)
        let legacy = Aria2TorrentEngine(executable: executable, directory: root.appendingPathComponent("LegacyEngine"),
                                       trackers: [], mapsPorts: false)
        let nativeModel = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Native"), engine: native)
        let legacyModel = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Legacy"), engine: legacy)
        defer { nativeModel.shutdown(); legacyModel.shutdown() }
        precondition(native.peerCensusInterval == 0 && nativeModel.censusInterval == 0)
        precondition(legacy.peerCensusInterval == 30 && legacyModel.censusInterval == 30)
        precondition(nativeModel.relayFileCensusInterval == 30 && legacyModel.relayFileCensusInterval == 30,
                     "Faster peer rates must not increase expensive file inventory polling")
        precondition(TorrentFixtureEngine().peerCensusInterval == 30)
        precondition(!native.running && !legacy.running, "Reading engine policies must not start a process")
        print("PASS peer-rate policies: native follows status; legacy keeps 30-second census; file polling unchanged; no engine started")
    }

    /// Counter-only jobs exercise refresh without loading any torrent metadata,
    /// starting a real torrent process, or inspecting downloaded files.
    @MainActor static func peerRatesFollowStatusCadence() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for interval in [TimeInterval(0), TimeInterval(30)] {
            let engine = TorrentFixtureEngine(); engine.running = true
            engine.peerCensusInterval = interval
            let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Counters-\(Int(interval))"), engine: engine)
            defer { model.shutdown() }
            let id = UUID(), gid = "counter-only"
            model.jobs = [LocalTorrentJob(id: id, name: "Synthetic counters", phase: .downloading)]
            model.gids[id] = gid
            precondition(model.censusInterval == interval)
            func report(_ down: UInt64, _ up: UInt64, state: String = "active", sockets: Int = 3) {
                engine.states[gid] = ["status":state, "connections":"\(sockets)", "numSeeders":"1",
                    "totalLength":"1000000", "completedLength":"100", "downloadSpeed":"\(down)", "uploadSpeed":"\(up)"]
                engine.connectedPeers = 3
                engine.peerDetail = [
                    .init(address:"203.0.113.1:6881", downloadSpeed:down, uploadSpeed:0, seeder:true),
                    .init(address:"203.0.113.2:6881", downloadSpeed:0, uploadSpeed:up / 2, seeder:false),
                    .init(address:"203.0.113.3:6881", downloadSpeed:0, uploadSpeed:up - up / 2, seeder:false),
                ]
            }
            func assertRates(_ down: UInt64, _ up: UInt64) {
                let peers = model.connectedPeers(id)
                precondition(model.job(id)?.downloadSpeed == down && model.job(id)?.uploadSpeed == up)
                precondition(peers.reduce(UInt64(0)) { $0 + $1.downloadSpeed } == down)
                precondition(peers.reduce(UInt64(0)) { $0 + $1.uploadSpeed } == up)
            }
            report(571_000, 224_000); await model.refresh(); assertRates(571_000, 224_000)
            let checks = engine.peerChecks, networkChecks = engine.networkChecks
            report(128_000, 64_000); await model.refresh()
            precondition(model.job(id)?.downloadSpeed == 128_000 && model.job(id)?.uploadSpeed == 64_000)
            if interval == 30 {
                precondition(engine.peerChecks == checks, "Legacy bitfield replies must remain throttled")
                precondition(model.connectedPeers(id)[0].downloadSpeed == 571_000)
                continue
            }
            assertRates(128_000, 64_000)
            precondition(engine.peerChecks == checks + 1, "Native peer rows must refresh with each successful status sample")

            engine.statusFailures = 1
            let attempts = model.job(id)?.attempted
            await model.refresh()
            precondition(model.connectedPeers(id).isEmpty && model.job(id)?.downloadSpeed == 0 && model.job(id)?.uploadSpeed == 0)
            precondition(model.job(id)?.peers == 3 && model.job(id)?.seeders == 1 && model.job(id)?.attempted == attempts,
                         "Lost status expires rates without inventing a peer disconnection")
            report(32_000, 16_000); await model.refresh(); assertRates(32_000, 16_000)

            engine.peerFailures = 1
            report(256_000, 96_000); await model.refresh()
            precondition(model.job(id)?.downloadSpeed == 256_000 && model.job(id)?.uploadSpeed == 96_000,
                         "A failed peer read must not discard valid aggregate rates")
            precondition(model.connectedPeers(id).isEmpty && model.job(id)?.peers == 3 && model.job(id)?.seeders == 1)
            let failedChecks = engine.peerChecks
            report(384_000, 48_000); await model.refresh(); assertRates(384_000, 48_000)
            precondition(engine.peerChecks == failedChecks + 1, "The next status poll must retry an expired peer sample")

            report(0, 0, state:"waiting"); await model.refresh()
            precondition(model.connectedPeers(id).isEmpty && model.job(id)?.peers == 0)
            report(512_000, 128_000); await model.refresh(); assertRates(512_000, 128_000)
            let connectedChecks = engine.peerChecks
            report(0, 0, sockets:0); engine.connectedPeers = 0; engine.peerDetail = []
            await model.refresh()
            precondition(model.connectedPeers(id).isEmpty && model.job(id)?.peers == 0)
            precondition(engine.peerChecks == connectedChecks,
                         "A zero-socket status must expire peer rows without reviving an older peer snapshot")
            report(64_000, 8_000); await model.refresh(); assertRates(64_000, 8_000)

            let relayIdentity = UUID()
            model.relayContextProvider = {
                .init(identity: relayIdentity, accountID: "synthetic",
                      engineURL: URL(fileURLWithPath: "/unused-counter-fixture"), environment: [:], credentialKind: .desktopOAuth)
            }
            model.edit(id) {
                $0.phase = .uploading
                $0.relay = TorrentRelayState(identity: relayIdentity, accountID: "synthetic", credentialKind: .desktopOAuth,
                    accountName: "Synthetic", parentID: "", parentName: "Synthetic", rootName: "Synthetic",
                    memoryBytes: 256 * 1024 * 1024, batches: [])
            }
            model.relayFileCensusAt[id] = Date()
            report(768_000, 192_000); await model.refresh(); assertRates(768_000, 192_000)
            precondition(model.job(id)?.phase == .uploading, "Peer sampling must also follow a live relay drain")
            precondition(engine.networkChecks == networkChecks, "Frequent peer samples must leave diagnostics at 30 seconds")
            precondition(engine.fileStatusChecks == 0, "Counter samples must never trigger a file inventory")
            precondition(engine.statusChecks > checks && engine.metadataRequests == 0 && engine.begun.isEmpty)

            // A late failure from a previous run must not expire a resumed
            // run's known peers, even at the stale-telemetry failure threshold.
            engine.delayStatusFailure = true
            model.statusFailures[id] = model.statusRetries - 1
            let oldRead = Task { try await model.pollStatus(id, gid: gid, files: false) }
            try await until("synthetic delayed status failure") { engine.statusFailureGate != nil }
            model.gids[id] = "counter-restarted"
            engine.statusFailureGate?.resume(); engine.statusFailureGate = nil
            let oldReply = try await oldRead.value
            precondition(oldReply == nil && model.job(id)?.peers == 3 && model.job(id)?.seeders == 1)
            precondition(model.statusFailures[id] == model.statusRetries - 1,
                         "A previous run must not change the current run's status failure count")
            precondition(model.job(id)?.downloadSpeed == 768_000 && !model.connectedPeers(id).isEmpty)
        }
        print("PASS native peer rates: successive download/upload samples align; failed reads expire rates, retain counts and recover; waiting/disconnected samples clear rows; relay drain and slower diagnostics preserved")
    }

    /// aria2's `connections` counts sockets it opened, not peers that answered.
    @MainActor static func peerHonesty() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Peers"), engine: engine)
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
        engine.peerDetail = [.init(address:"203.0.113.7:51413", downloadSpeed:4096, uploadSpeed:0, seeder:true),
                             .init(address:"[2001:db8::5]:6881", downloadSpeed:0, uploadSpeed:512, seeder:false),
                             .init(address:"198.51.100.2:6881", downloadSpeed:0, uploadSpeed:0, seeder:false)]
        report("13"); await model.refresh()
        precondition(model.job(id)?.peers == 3 && model.job(id)?.attempted == 13)
        let detail = model.connectedPeers(id)
        precondition(detail.count == 3 && detail[0].downloadSpeed == 4096 && detail[1].uploadSpeed == 512)
        precondition(detail.filter(\.active).count == 2, "Only peers moving bytes count as active")
        await model.pause(id)
        precondition(model.connectedPeers(id).isEmpty, "A paused torrent must not keep showing a stale swarm")
        await model.resume(id)
        try await until("peer census resumes") { model.job(id)?.phase.active == true }
        await model.refresh()
        // A cached census must never outlive the sockets it was counted from.
        model.censusInterval = 600
        report("0"); await model.refresh()
        precondition(model.job(id)?.peers == 0, "Losing every socket must drop the peer count without waiting for a census")
        // ...and the count must climb back the moment sockets return. Only a
        // census can raise it, so a throttled one pins the card at zero long
        // after aria2 reconnected.
        engine.connectedPeers = 4
        report("9"); await model.refresh()
        precondition(model.job(id)?.peers == 4, "Sockets returning must re-census instead of waiting out the census window")
        print("PASS peers: connected peers come from the peer list, never outlive aria2's open sockets, and recover as soon as sockets do.")
    }

    @MainActor static func networkDiagnosticsCadence() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        engine.connectedPeers = 0
        engine.networkState = .init(["knownPeers": 42, "trackerCount": 4, "trackersResponding": 1,
                                    "trackersFailed": 3, "lastPeerError": "Connection timed out"],
                                   dht: ["enabled": true, "snapshotReady": true, "nodes": 9])
        let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root, engine: engine)
        model.censusInterval = 0
        defer { model.shutdown() }
        let id = try model.add(magnet: magnet)
        try await until("network diagnostics ready") { engine.metadataRequests == 1 && !model.busy.contains(id) }
        engine.states[model.gids[id]!] = ["status": "active", "connections": "7", "downloadSpeed": "0"]
        await model.refresh()
        precondition(model.networkDetails[id] == engine.networkState)
        precondition(model.job(id)?.peers == 0 && model.job(id)?.attempted == 7,
                     "Discovered addresses must never inflate completed peer connections")
        let checks = engine.networkChecks
        for _ in 0..<3 { await model.refresh() }
        precondition(engine.networkChecks == checks, "A zero-peer recensus must not increase network diagnostics polling")
        let saved = try Data(contentsOf: root.appendingPathComponent("queue-v1.json"))
        precondition(!String(decoding: saved, as: UTF8.self).contains("trackersResponding"),
                     "Network diagnostics must not enter the saved torrent queue")
        print("PASS network diagnostics: discovered addresses remain separate from peers; frequent zero-peer censuses keep diagnostics throttled and unsaved")
    }

    /// The relay tolerates a dropped status reply; a local download must too,
    /// rather than blanking its swarm and rates over one lost packet.
    @MainActor static func localStatusHiccup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(); let (model, id) = try await prepared(root: root, engine: engine)
        defer { model.shutdown() }
        model.censusInterval = 0
        engine.connectedPeers = 5
        await model.download(id, selected: [2], to: root)
        precondition(model.job(id)?.phase == .downloading)
        engine.states[model.gids[id]!] = ["status":"active", "connections":"7", "numSeeders":"2",
                                          "downloadSpeed":"4096", "uploadSpeed":"128"]
        await model.refresh()
        precondition(model.job(id)?.peers == 5 && model.job(id)?.downloadSpeed == 4096)
        engine.statusFailures = 2
        await model.refresh()
        precondition(model.job(id)?.phase == .downloading, "A dropped status reply must not stop a download")
        precondition(model.job(id)?.peers == 5 && model.job(id)?.seeders == 2, "A dropped reply must not blank the swarm")
        precondition(model.job(id)?.downloadSpeed == 0, "A rate nobody reported must not be shown")
        precondition(model.job(id)?.message == "Reconnecting to download status…")
        engine.statusFailures = 99
        // Drive retry policy independently of the energy-saving poll interval.
        for _ in 0..<model.statusRetries { await model.refresh() }
        precondition(model.job(id)?.peers == 0, "A status that never returns must clear stale peers")
        print("PASS local downloads: a dropped status reply keeps the swarm on screen; a lasting one clears it")
    }

    /// Completed files must stop waiting for company once the buffer fills:
    /// RAM already saved to PikPak is the cheapest space a transfer can reclaim.
    static func flushPressure() {
        let gib: UInt64 = 1024 * 1024 * 1024
        func flush(_ count: Int, used: UInt64, capacity: UInt64) -> Bool {
            TorrentRelayDrain.shouldFlush(count: count, bytes: 1, waiting: 0, windowComplete: false,
                                          used: used, capacity: capacity)
        }
        precondition(!flush(1, used: gib, capacity: 4 * gib), "A roomy buffer keeps the ordinary limits")
        precondition(flush(1, used: 3 * gib, capacity: 4 * gib), "A filling buffer flushes what is queued")
        precondition(!flush(0, used: 4 * gib, capacity: 4 * gib), "Pressure with nothing queued is not a flush")
        precondition(!flush(1, used: 0, capacity: 0), "An unreadable volume falls back to the ordinary limits")
        print("PASS drain pressure: a filling buffer flushes queued files without waiting out the timer")
    }

    /// aria2 reports every peer as strings, including addresses it cannot
    /// place. The list carried into the UI must be ranked, bounded and readable.
    @MainActor static func peerListParsing() {
        func peer(_ ip: String, _ port: String, down: String, up: String, seeder: String = "false") -> [String: Any] {
            ["ip":ip, "port":port, "downloadSpeed":down, "uploadSpeed":up, "seeder":seeder, "handshakeCompleted":"true"]
        }
        let zeroID = String(repeating: "%00", count: 20)
        let knownID = "-UT2210-" + String(repeating: "%aB", count: 12)
        precondition(!Aria2TorrentEngine.peerIsConnected(["peerId":zeroID]))
        precondition(!Aria2TorrentEngine.peerIsConnected(["peerId":""]))
        precondition(!Aria2TorrentEngine.peerIsConnected(["peerId":"%xx"]))
        precondition(!Aria2TorrentEngine.peerIsConnected(["peerId":String(repeating: "a", count: 19)]))
        precondition(!Aria2TorrentEngine.peerIsConnected(["peerId":String(repeating: "a", count: 21)]))
        precondition(Aria2TorrentEngine.peerIsConnected(["peerId":knownID]), "Binary IDs need not be UTF-8")
        precondition(!Aria2TorrentEngine.peerIsConnected(["peerId":knownID, "handshakeCompleted":"false"]), "An old ID must not count a pending reconnect")
        precondition(Aria2TorrentEngine.peerIsConnected(["peerId":zeroID, "handshakeCompleted":"true"]), "The engine flag is authoritative")
        var pending = peer("198.51.100.8", "6881", down: "0", up: "0")
        pending["handshakeCompleted"] = "false"; pending["peerId"] = knownID
        let parsed = Aria2TorrentEngine.peerList([
            pending,
            peer("198.51.100.9", "6881", down: "0", up: "0"),
            peer("", "6881", down: "9999", up: "0"),
            peer("2001:db8::1", "51413", down: "2048", up: "16", seeder: "true"),
            peer("203.0.113.4", "6881", down: "0", up: "4096"),
        ])
        precondition(parsed.count == 3, "A peer without an address cannot be listed")
        precondition(parsed[0].address == "203.0.113.4:6881", "The busiest peer leads")
        precondition(parsed[1].address == "[2001:db8::1]:51413" && parsed[1].seeder, "An IPv6 literal keeps its port readable")
        precondition(parsed[2].address == "198.51.100.9:6881" && !parsed[2].active)
        let crowd = (1...120).map { peer("198.51.100.\($0 % 250)", "\(6881 + $0)", down: "\($0)", up: "0") }
        precondition(Aria2TorrentEngine.peerList(crowd).count == Aria2TorrentEngine.maximumPeersListed, "A large swarm must not grow the list without bound")
        print("PASS peer detail: addresses, per-peer rates, seeds ranked by activity and capped")
    }

    /// libtorrent writes a peer off after three failed dials and revives it only
    /// when a tracker lists it again, so cached seeders must be offered more than
    /// once per run: otherwise one that went offline is never dialed again.
    @MainActor static func peerRedialCadence() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func due(restored: Date?, attempted: Date?, after seconds: TimeInterval) -> Bool {
            TorrentRPCEngine.peerRestoreDue(restoredAt: restored, attemptedAt: attempted, now: start.addingTimeInterval(seconds))
        }
        precondition(due(restored: nil, attempted: nil, after: 0), "Cached peers are offered as soon as a torrent runs")
        precondition(!due(restored: nil, attempted: start, after: 4), "A failed offer is not resent on every poll")
        precondition(due(restored: nil, attempted: start, after: 5), "A failed offer is retried once the peer store can exist")
        precondition(!due(restored: start, attempted: start, after: 60), "Offered hints are not resent on every status poll")
        precondition(due(restored: start, attempted: start, after: TorrentRPCEngine.peerRedialInterval),
                     "A seeder libtorrent wrote off must be offered again while the torrent runs")
        print("PASS peer redial: first offer at once, 5 s retry after a failed offer, repeated every \(Int(TorrentRPCEngine.peerRedialInterval)) s")
    }

    @MainActor static func peerCachePersistence() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = TorrentPeerCache(directory: root.appendingPathComponent("Peers"))
        let hash = String(repeating: "a", count: 40), other = String(repeating: "b", count: 40)
        let now = Date()
        func peer(_ address: String, moving: Bool = false, seed: Bool = false) -> LocalTorrentPeer {
            .init(address: address, downloadSpeed: moving ? 1024 : 0, uploadSpeed: 0, seeder: seed)
        }
        let working = peer("203.0.113.7:51413", moving: true, seed: true)
        let ipv6 = peer("[2001:db8::7]:6881")
        try cache.record(hash, peers: [working, ipv6, working,
            peer("127.0.0.1:6881"), peer("192.168.1.1:6881"), peer("198.18.0.9:6881"),
            peer("10.1.1.1:6881"), peer("100.64.0.1:6881"), peer("224.0.0.1:6881"),
            peer("[::1]:6881"), peer("[fe80::1]:6881"), peer("[::ffff:127.0.0.1]:6881"),
            peer("example.com:6881"), peer("203.0.113.8:0"), peer("203.0.113.8:65536")], now: now)
        let restored = TorrentPeerCache(directory: cache.directory).load(hash, now: now)
        precondition(restored.map(\.address) == [working.address, ipv6.address], "Only deduplicated public literal endpoints are restored, useful peers first")
        precondition(restored.first?.transferred == true && restored.first?.rpcValue["port"] as? Int == 51413)
        precondition(cache.load(other, now: now).isEmpty, "Peer hints belong to one torrent hash")
        precondition(cache.load("../" + hash, now: now).isEmpty)
        precondition(cache.load(hash, now: now.addingTimeInterval(TorrentPeerCache.lifetime + 1)).isEmpty, "Old endpoints expire")
        precondition(cache.load(hash, now: now.addingTimeInterval(-120)).isEmpty, "Future timestamps are not trusted")
        let file = cache.directory.appendingPathComponent(hash + ".json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600, "Connection hints stay in a private file")

        try cache.record(hash, peers: [peer(working.address)], now: now.addingTimeInterval(10))
        precondition(cache.load(hash, now: now.addingTimeInterval(10)).first?.transferred == true, "Idle polls retain proof of a working connection")
        let pending: [[String: Any]] = [["ip":"203.0.113.9", "port":"6881", "handshakeCompleted":"false", "peerId":String(repeating: "a", count: 20)]]
        try cache.record(hash, peers: Aria2TorrentEngine.peerList(pending), now: now)
        precondition(cache.load(hash, now: now).count == 2, "Remembered peer IDs cannot cache an unfinished handshake")
        let crowd = (1...100).map { peer("198.51.100.\($0):6881") }
        try cache.record(hash, peers: crowd, now: now.addingTimeInterval(20))
        let bounded = cache.load(hash, now: now.addingTimeInterval(20))
        precondition(bounded.count == TorrentPeerCache.maximumPeers && bounded.first?.address == working.address)

        let original = try Data(contentsOf: file)
        var wrongHash = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        wrongHash["infoHash"] = other
        try LocalTorrentStore.write(JSONSerialization.data(withJSONObject: wrongHash), to: file)
        precondition(cache.load(hash, now: now).isEmpty, "A misplaced cache cannot introduce another torrent's peers")
        try LocalTorrentStore.write(Data(repeating: 65, count: 33 * 1024), to: file)
        precondition(cache.load(hash, now: now).isEmpty, "Oversized or corrupt cache data is optional and ignored")
        try LocalTorrentStore.write(original, to: file)
        let link = root.appendingPathComponent("LinkedPeers")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cache.directory)
        precondition(TorrentPeerCache(directory: link).load(hash, now: now).isEmpty, "Peer caches must not follow a substituted directory")
        print("PASS peer cache: restart persistence, torrent binding, expiry, bounds, public endpoints, private permissions, corrupt/symlink fallback")
    }

    @MainActor static func metadataRetries() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine()
        let actual = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("Retries"), engine: engine)
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

    /// Can a live download's file selection be *grown*?
    ///
    /// Everything this app does today only ever narrows one, and the rolling
    /// RAM design in docs/TORRENT_RAM_ROLLING_SELECTION.md is worthless if
    /// adding a file makes aria2 re-verify what it already has or drop the
    /// swarm it took minutes to build. Asked against real peers.
    @MainActor static func actualSelectionGrowth(_ fixture: URL) async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let root = fixture.deletingLastPathComponent()
        let options = ["enable-dht":"false","enable-dht6":"false","enable-peer-exchange":"false","bt-enable-lpd":"false",
                       "listen-port":"\(config["leecher_port"] as! Int)","max-overall-download-limit":"64K","bt-tracker-interval":"2"]
        let executable = URL(fileURLWithPath: config["engine"] as! String)
        let state = root.appendingPathComponent("GrowQueue")
        let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: state, engine: fixtureEngine(executable: executable, directory: state.appendingPathComponent("Engine"), extraOptions: options, trackers: [], mapsPorts: false))
        defer { model.shutdown() }
        let id = try model.add(magnet: config["magnet"] as! String)
        try await until("real magnet file list", seconds: 45) { model.job(id)?.phase != .metadata }
        guard model.job(id)?.phase == .choosing else { throw LocalTorrentError.message(model.job(id)?.message ?? "No file list") }
        let output = root.appendingPathComponent("Grown"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Start with one file, the way a rolling admission would.
        await model.download(id, selected: [1], to: output)
        guard model.job(id)?.phase == .downloading, let gid = model.gids[id] else { throw LocalTorrentError.message(model.error ?? "Download did not start") }
        model.censusInterval = 0.5
        try await until("a live transfer to interrupt", seconds: 45) {
            (model.job(id)?.completed ?? 0) > 0 && (model.job(id)?.peers ?? 0) > 0
        }
        let before = model.job(id)!.completed, peersBefore = model.job(id)!.peers
        let directory = URL(fileURLWithPath: model.job(id)!.destination!).appendingPathComponent("FixtureFiles")

        model.busy.insert(id)
        try await model.engine.reselect(gid, selection: [1, 3])
        model.busy.remove(id)

        var lowestCompleted = before, highestCompleted = before, sawPeer = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 400_000_000)
            await model.refresh()
            guard let job = model.job(id) else { break }
            lowestCompleted = Swift.min(lowestCompleted, job.completed)
            highestCompleted = Swift.max(highestCompleted, job.completed)
            if job.peers > 0 { sawPeer = true }
        }
        print("   grew selection at \(before) bytes with \(peersBefore) peer(s): completed fell to \(lowestCompleted), rose to \(highestCompleted), peers seen again: \(sawPeer)")
        // 1. Nothing already verified may be thrown away.
        precondition(lowestCompleted >= before,
                     "Growing the selection re-verified \(before - lowestCompleted) bytes of finished work")
        // 2. The transfer must carry on through the change — the strongest
        //    evidence the swarm survived it.
        precondition(highestCompleted > before, "The download stalled after the selection changed")
        precondition(sawPeer, "No peer remained after the selection changed")
        // 3. The added file must actually arrive.
        try await until("the added file downloads", seconds: 60) {
            (try? Data(contentsOf: directory.appendingPathComponent("note.txt")))?.isEmpty == false
        }
        for name in ["keep.bin", "note.txt"] {
            try await until("\(name) completes", seconds: 60) {
                let received = try? Data(contentsOf: directory.appendingPathComponent(name))
                let original = try? Data(contentsOf: root.appendingPathComponent("Seed/FixtureFiles/" + name))
                return received != nil && original != nil && received!.count == original!.count
            }
            let received = try Data(contentsOf: directory.appendingPathComponent(name))
            let original = try Data(contentsOf: root.appendingPathComponent("Seed/FixtureFiles/" + name))
            precondition(SHA256.hash(data: received) == SHA256.hash(data: original), "\(name) differs from the seed")
        }
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("skip.bin").path),
                     "A file never selected must stay unselected")
        await model.stop(id)
        print("PASS selection growth: a live aria2 selection accepted a new file, kept transferring and re-verified nothing")
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
            LocalTorrentModel(dnsProbe: { _ in .clean }, directory: state, engine: fixtureEngine(executable: executable, directory: state.appendingPathComponent("Engine"), extraOptions: options, trackers: [], mapsPorts: false))
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
        let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root, engine: engine, ram: RelayFixtureRAM())
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
    var availableOverride: UInt64?
    var released = 0
    var clears = 0
    var failRelease = false
    var beforeRelease: ((TorrentRAMVolume) throws -> Void)?
    func acquire(id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume {
        if let volume = volumes[id] { return volume }
        let mount = directory.appendingPathComponent("synthetic-ram")
        try LocalTorrentStore.protect(mount.appendingPathComponent("payload"))
        let volume = TorrentRAMVolume(device: "fixture", image: "ram://fixture", volumeDevice: "fixture", uuid: UUID().uuidString, mount: mount.path, owner: id, bytes: bytes)
        volumes[id] = volume; return volume
    }
    func validate(_ volume: TorrentRAMVolume) async throws { precondition(volumes[volume.owner] == volume) }
    func availableBytes(_ volume: TorrentRAMVolume) throws -> UInt64 { availableOverride ?? volume.bytes }
    func clear(_ volume: TorrentRAMVolume) async throws { try await validate(volume); clears += 1 }
    func release(_ volume: TorrentRAMVolume) async throws {
        try beforeRelease?(volume)
        if failRelease { throw LocalTorrentError.message("Synthetic RAM release failure") }
        volumes[volume.owner] = nil; released += 1
    }
}
@MainActor final class RelayFixtureCloud {
    var receipts = Set<Int>()
    var uploads: [Int] = []
    var invocations = 0
    var blockUploads = false
    var blockReconcile = false
    var failAfterFirst = false
    var offline = false
    var loseCommitReply = false
    var requests: [[String: Any]] = []
    var credentialKinds: [PikPakCredentialKind] = []
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
        cloud.requests.append(request)
        cloud.credentialKinds.append(context.credentialKind)
        if cloud.offline { throw URLError(.notConnectedToInternet) }
        let reconcile = request["reconcile_only"] as? Bool == true
        // Model an already in-flight cloud check returning after Pause. It
        // must not start a new upload helper until an explicit Resume.
        while reconcile && cloud.blockReconcile {
            try Task.checkCancellation(); if stopped { throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        for source in request["files"] as! [[String: Any]] {
            let index = source["index"] as! Int
            if cloud.receipts.contains(index) { event(["event":"committed", "index":index]); continue }
            if reconcile { continue }
            event(["event":"hashing", "index":index])
            while cloud.blockUploads || paused { try Task.checkCancellation(); if stopped { throw CancellationError() }; try await Task.sleep(nanoseconds: 20_000_000) }
            try Task.checkCancellation()
            cloud.uploads.append(index); cloud.receipts.insert(index)
            if cloud.loseCommitReply { cloud.loseCommitReply = false; throw URLError(.networkConnectionLost) }
            event(["event":"committed", "index":index])
            if cloud.failAfterFirst { cloud.failAfterFirst = false; throw LocalTorrentError.message("Synthetic lost upload reply") }
        }
        event(["event":"finished"])
    }
}

extension LocalTorrentTests {
    @MainActor static func storageCopySafety() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let conflicting = [LocalTorrentFile(index: 1, path: "Collection/one.bin", length: 1),
                           LocalTorrentFile(index: 2, path: "collection/two.bin", length: 1)]
        try TorrentRelayStorage.validateLayout(conflicting, caseSensitive: true)
        do { try TorrentRelayStorage.validateLayout(conflicting, caseSensitive: false); preconditionFailure("Later windows could merge distinct case-sensitive folders") } catch {}
        do {
            try TorrentRelayStorage.validateLayout([.init(index: 1, path: "A", length: 1), .init(index: 2, path: "a/child", length: 1)], caseSensitive: false)
            preconditionFailure("File/directory collision accepted")
        } catch {}
        let source = root.appendingPathComponent("RAM"), owner = UUID()
        try LocalTorrentStore.protect(source.appendingPathComponent("Nested"))
        let sparse = source.appendingPathComponent("Nested/partial.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: Data("first piece".utf8))
        let writer = try FileHandle(forWritingTo: sparse)
        try writer.seek(toOffset: 512 * 1024 * 1024)
        try writer.write(contentsOf: Data("last piece".utf8)); try writer.close()
        let checkpoint = Data("existing aria2 piece map".utf8)
        try checkpoint.write(to: source.appendingPathComponent("Nested.aria2"))
        let storage = try TorrentRelayStorage.create(in: root, owner: owner)
        try await storage.copy(from: source) { _ in }
        try storage.validate(owner: owner)
        let copied = storage.payload.appendingPathComponent("Nested/partial.bin")
        let reader = try FileHandle(forReadingFrom: copied)
        let start = try reader.read(upToCount: 11)
        try reader.seek(toOffset: 512 * 1024 * 1024)
        let end = try reader.readToEnd(); try reader.close()
        let saved = try Data(contentsOf: storage.payload.appendingPathComponent("Nested.aria2"))
        precondition(start == Data("first piece".utf8) && end == Data("last piece".utf8) && saved == checkpoint)
        let allocated = try storage.space()
        precondition(allocated.used < 8 * 1024 * 1024, "Migration must preserve sparse torrent files")
        do { try storage.validate(owner: UUID()); preconditionFailure("Wrong storage owner accepted") } catch {}
        do { _ = try TorrentRelayStorage.file("../outside", under: storage.payload); preconditionFailure("Escaping cleanup path accepted") } catch {}
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let link = storage.payload.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try TorrentRelayStorage.file("link", under: storage.payload); preconditionFailure("Cleanup followed a symlink") } catch {}
        try FileManager.default.removeItem(at: link)
        try storage.clear()
        let untouched = try Data(contentsOf: outside)
        precondition(untouched == Data("keep".utf8))
        print("PASS storage copy: sparse partial bytes and aria2 checkpoints preserved; case collisions, owner, cleanup paths and unrelated files protected")
    }

    @MainActor static func relayStorageMigration() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let files: [(String, UInt64)] = [("Examples/one", 32768), ("Examples/two", 32768), ("Examples/three", 32768)]
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        model.edit(id) { $0.relay?.keepUploadedFiles = false }
        model.relayFlushWait = 0; model.relayFileCensusInterval = 0
        let volume = model.job(id)!.relay!.volume!, oldGID = model.gids[id]!
        try LocalTorrentStore.protect(volume.payload.appendingPathComponent("Examples"))
        let partial = Data(repeating: 0x71, count: 8192), checkpoint = Data("partial pieces".utf8)
        try Data(repeating: 1, count: 32768).write(to: volume.payload.appendingPathComponent(files[0].0))
        try partial.write(to: volume.payload.appendingPathComponent(files[1].0))
        try checkpoint.write(to: volume.payload.appendingPathComponent("Examples.aria2"))
        engine.setFileProgress(oldGID, [1: 32768, 2: 8192]); cloud.blockUploads = true
        await model.refresh()
        try await until("upload held during storage migration") { model.job(id)?.relay?.stage == "hashing" && !model.busy.contains(id) }
        // Simulate a confirmed cloud upload whose response has not arrived yet.
        cloud.receipts.insert(1)
        let progress = model.job(id)!.downloadedBytes
        ram.beforeRelease = { _ in
            let saved = try model.store.load().first { $0.id == id }!
            precondition(saved.relay?.storage != nil && saved.relay?.volume != nil, "Both copies must be recorded before RAM is released")
            let copied = try Data(contentsOf: saved.relay!.storage!.payload.appendingPathComponent(files[1].0))
            precondition(copied == partial)
        }
        await model.switchRelayToStorage(id, parent: root)
        try await until("storage download resumes") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        let state = model.job(id)!.relay!, storage = state.storage!, gid = model.gids[id]!
        precondition(gid != oldGID && engine.states[oldGID] == nil)
        precondition(engine.directories[gid] == storage.payload && state.volume == nil && ram.volumes.isEmpty)
        precondition(state.uploaded == [1] && cloud.uploads.isEmpty, "Migration must reconcile a lost upload reply")
        precondition(model.job(id)!.downloadedBytes >= progress && !model.job(id)!.canSwitchRelayToStorage)
        let copied = try Data(contentsOf: storage.payload.appendingPathComponent(files[1].0))
        let resumedCheckpoint = try Data(contentsOf: storage.payload.appendingPathComponent("Examples.aria2"))
        precondition(copied == partial && resumedCheckpoint == checkpoint)
        precondition(!FileManager.default.fileExists(atPath: storage.payload.appendingPathComponent(files[0].0).path))
        // Live cleanup releases committed files even with ample free storage,
        // while the remaining files keep their existing peer connections.
        let selections = engine.reselected.count, starts = engine.begun.count, pauses = engine.pauses.count
        cloud.blockUploads = false
        try Data(repeating: 2, count: 32768).write(to: storage.payload.appendingPathComponent(files[1].0))
        try partial.write(to: storage.payload.appendingPathComponent(files[2].0))
        engine.setFileProgress(gid, [2: 32768, 3: 8192]); await model.refresh()
        try await until("storage file uploaded") { model.job(id)?.relay?.uploaded.contains(2) == true && model.relayTasks[id] == nil }
        for _ in 0..<3 { await model.refresh() }
        precondition(!FileManager.default.fileExists(atPath: storage.payload.appendingPathComponent(files[1].0).path))
        precondition(engine.reselected.count == selections && engine.begun.count == starts && engine.pauses.count == pauses,
                     "Eager disk cleanup must not reset a productive torrent's peer connections")
        precondition(engine.releases.last?.1 == [2] && model.job(id)?.relay?.drained?.contains(2) == true)
        precondition(model.job(id)?.phase == .downloading)
        precondition(model.job(id)?.completed == 65536 && model.job(id)?.downloadedBytes == 73728)
        precondition(model.job(id)?.downloadedAwaitingPikPakBytes == 8192,
                     "Only the partial unsaved file belongs in downloaded-but-not-saved progress")
        precondition(cloud.requests.last?["ram_root"] as? String == storage.payload.path)
        precondition(cloud.requests.allSatisfy { $0["parent_id"] as? String == state.parentID && $0["root_name"] as? String == state.rootName })
        try Data(repeating: 3, count: 32768).write(to: storage.payload.appendingPathComponent(files[2].0))
        engine.setFileProgress(gid, [2: 32768, 3: 32768]); await model.refresh()
        try await until("storage cleanup after remaining file uploads") { model.job(id)?.phase == .completed }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: storage.payload.path)
        precondition(leftovers.isEmpty && cloud.uploads == [2, 3])
        precondition(model.job(id)?.downloadedAwaitingPikPakBytes == 0 && model.job(id)?.relay?.bufferUsed == 0)
        print("PASS RAM → storage: partials/checkpoint migrated, lost receipt reconciled, uploads preserve connected downloads, final payload reclaimed")
    }

    @MainActor static func eagerStorageCleanup() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let files = (1...4).map { ("Shared/file\($0)", UInt64(700)) }
        let (model, engine, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        model.edit(id) { $0.relay?.keepUploadedFiles = false }
        model.edit(id) { $0.pieceLength = 1000 }
        await model.switchRelayToStorage(id, parent: root)
        try await until("eager storage fixture ready") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        model.relayFlushWait = 0; model.relayFileCensusInterval = 0
        let gid = model.gids[id]!, state = model.job(id)!.relay!, payload = state.payload!
        try LocalTorrentStore.protect(payload.appendingPathComponent("Shared"))
        for file in files { try Data(repeating: 0x73, count: 700).write(to: payload.appendingPathComponent(file.0)) }
        func exists(_ index: Int) -> Bool { FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[index - 1].0).path) }
        let pauses = engine.pauses.count, starts = engine.begun.count, changes = engine.reselected.count
        engine.setFileProgress(gid, [1: 700, 2: 200, 3: 100, 4: 100]); await model.refresh()
        try await until("first shared file uploaded") { cloud.uploads == [1] && model.relayTasks[id] == nil }
        await model.refresh()
        precondition(exists(1) && engine.releases.isEmpty, "An unfinished shared-piece neighbour pins the uploaded file")
        precondition(model.job(id)!.completed + model.job(id)!.relay!.bufferUsed! > model.job(id)!.downloadedBytes,
                     "Storage and cloud counts can still overlap while shared pieces are pinned")
        engine.setFileProgress(gid, [1: 700, 2: 700, 3: 100, 4: 100]); await model.refresh()
        try await until("second file uploaded") { cloud.uploads == [1, 2] && model.relayTasks[id] == nil }
        precondition(!exists(1) && exists(2) && exists(3) && exists(4))
        precondition((model.job(id)?.relay?.bufferAvailable ?? 0) > 1024 * 1024,
                     "Removal must happen without storage pressure")
        engine.setFileProgress(gid, [1: 700, 2: 700, 3: 700, 4: 100])
        engine.checkingOnFileCensus = true
        let releases = engine.releases.count
        await model.refresh()
        precondition(exists(2) && engine.releases.count == releases, "Verification must finish before release")
        engine.checkingOnFileCensus = false; engine.releaseFailures = 1
        await model.refresh()
        precondition(exists(2) && model.job(id)?.phase.active == true, "Cleanup RPC failure must retain the file and download")
        await model.refresh()
        precondition(!exists(2) && exists(3) && exists(4), "Retry should reclaim only uploaded, piece-safe files")
        precondition(engine.pauses.count == pauses && engine.begun.count == starts && engine.reselected.count == changes)
        precondition(model.gids[id] == gid && model.job(id)?.relay?.selection == state.selection)
        try await until("uploaded receipts settled before fixture restart") { model.relayTasks[id] == nil }
        let uploaded = model.job(id)!.relay!.uploaded
        await model.pauseRelay(id, automatic: true); model.shutdown()
        let nextEngine = TorrentFixtureEngine(); nextEngine.files = files
        let next = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: model.store.directory, engine: nextEngine, ram: ram)
        defer { next.shutdown() }
        next.relayContextProvider = { context }; next.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        await next.resumeRestoredTransfers()
        try await until("eager cleanup resumes without reselecting saved files") { next.job(id)?.phase == .downloading && !next.busy.contains(id) }
        precondition(uploaded.isDisjoint(with: Set(next.job(id)?.relay?.selection ?? [])),
                     "A restart must not download entire uploaded files retained in the old live selection")
        precondition(next.job(id)?.relay?.selection?.contains(4) == true)
        print("PASS eager storage cleanup: no pressure wait; shared/unuploaded files retained, verification respected, failed cleanup retried without pausing peers, restart skips cloud-saved files")
    }

    @MainActor static func retainedStorageFiles() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let files: [(String, UInt64)] = [("Examples/one", 32768), ("Examples/two", 32768), ("Examples/three", 32768)]
        let (model, engine, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        await model.switchRelayToStorage(id, parent: root)
        try await until("retention fixture ready") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        model.relayFlushWait = 0; model.relayFileCensusInterval = 0
        let gid = model.gids[id]!, payload = model.job(id)!.relay!.payload!
        precondition(model.job(id)!.relay!.keepsUploadedFiles)
        try LocalTorrentStore.protect(payload.appendingPathComponent("Examples"))
        try Data(repeating: 3, count: 32768).write(to: payload.appendingPathComponent(files[0].0))
        engine.setFileProgress(gid, [1: 32768, 2: 8192]); await model.refresh()
        try await until("retained file uploads") { cloud.uploads == [1] && model.relayTasks[id] == nil }
        let pauses = engine.pauses.count, begins = engine.begun.count
        for _ in 0..<3 { await model.refresh() }
        precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[0].0).path))
        precondition(engine.releases.isEmpty && engine.pauses.count == pauses && engine.begun.count == begins,
                     "Sharing must retain verified bytes and the active peer session while space is available")
        await model.pauseRelay(id, automatic: true); model.shutdown()
        let nextEngine = TorrentFixtureEngine(); nextEngine.files = files
        let next = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: model.store.directory, engine: nextEngine, ram: ram)
        defer { next.shutdown() }
        next.relayContextProvider = { context }; next.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        next.relayFileCensusInterval = 0
        await next.resumeRestoredTransfers()
        try await until("retained storage resumes") { next.job(id)?.phase == .downloading && !next.busy.contains(id) }
        precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[0].0).path))
        precondition(next.job(id)?.relay?.selection == [2, 3] && cloud.uploads == [1],
                     "Retained uploads must survive restart without being selected for download or uploaded twice")
        next.setKeepUploadedFiles(id, enabled: false)
        let saved = try next.store.load().first { $0.id == id }!
        precondition(saved.relay?.keepUploadedFiles == false)
        nextEngine.setFileProgress(next.gids[id]!, [1: 32768, 2: 8192]); await next.refresh()
        precondition(!FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[0].0).path))
        precondition(nextEngine.releases.last?.1 == [1], "Immediate cleanup must remain available through the saved setting")
        print("PASS disk sharing: uploaded files retained without reconnecting, restart preserves bytes and skips duplicate downloads/uploads, immediate cleanup setting persists")
    }

    static func storageRetentionBudget() {
        let gib = TorrentRelayDrain.storageGB
        precondition(TorrentRelayDrain.storageLimit(capacity: 500 * gib, configured: nil) == 400 * gib)
        precondition(TorrentRelayDrain.storageLimit(capacity: 80 * gib, configured: nil) == 0)
        precondition(TorrentRelayDrain.storageLimit(capacity: 500 * gib, configured: 100 * gib) == 100 * gib)
        func target(_ free: UInt64, _ reserved: UInt64, _ next: UInt64? = nil) -> UInt64 {
            TorrentRelayDrain.storageReleaseTarget(available: free, used: 100 * gib, limit: 150 * gib,
                reserved: reserved, nextFile: next, pieceLength: 16_384)
        }
        precondition(target(400 * gib, 10 * gib) == 0, "Spare disk must retain uploaded pieces well beyond 60 GB")
        precondition(target(80 * gib, 100 * gib) > 50 * gib, "Unwritten admitted bytes must be reserved before retaining copies")
        precondition(target(80 * gib, 30 * gib, 40 * gib) > 20 * gib, "Reclamation must make room for the next waiting file")
        precondition(target(0, .max, .max) == .max, "Reservation overflow must not allow extra retention")
        let files = [LocalTorrentFile(index: 1, path: "saved", length: 100 * gib)]
        let reservation = TorrentRelayDrain.admit(files: files, wanted: [1], uploaded: [1], active: [1],
            progress: [:], available: 0, budget: nil, pieceLength: 16384)
        precondition(reservation.reservedBytes == 4096 + 32768,
                     "Uploaded files already on disk must not reserve their entire length a second time")
        let shrink = TorrentRelayDrain.storageReleaseTarget(available: 400 * gib, used: 200 * gib, limit: 100 * gib,
            reserved: 0, nextFile: nil, pieceLength: 16384)
        precondition(shrink >= 100 * gib && shrink < 101 * gib, "200 → 100 GB must reclaim the excess, not the whole cache")
        let partial = (1...4).map { LocalTorrentFile(index: $0, path: "file\($0)", length: 100 * gib) }
        let reduced = TorrentRelayDrain.admitStorage(files: partial, wanted: [1, 2, 3, 4], uploaded: [1],
            active: [1, 2, 3, 4], progress: [1: 100 * gib, 2: 90 * gib, 3: 80 * gib],
            available: 400 * gib, used: 270 * gib, limit: 100 * gib, pieceLength: 16384, starting: false)
        precondition(reduced.selection == [1, 2] && reduced.blockedOnSpace,
                     "Over-limit partials must narrow to the nearest complete file and preserve completed uploads")
        print("PASS storage limits: automatic minus 100 GB, custom cap, 200 → 100 GB reclamation, partial-file convergence and overflow")
    }

    @MainActor static func liveStorageLimit() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let files = (1...20).map { ("Examples/file\($0)", UInt64(100_000_000)) }
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        await model.switchRelayToStorage(id, parent: root)
        try await until("live limit fixture ready") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        let gid = model.gids[id]!, payload = model.job(id)!.relay!.payload!
        model.relayFileCensusInterval = 0
        try LocalTorrentStore.protect(payload.appendingPathComponent("Examples"))
        let marker = Data("preserved partial bytes".utf8)
        try marker.write(to: payload.appendingPathComponent(files[2].0))
        engine.setFileProgress(gid, Dictionary(uniqueKeysWithValues: (1...20).map { ($0, UInt64(10_000_000)) }))
        model.setStorageLimit(id, bytes: TorrentRelayDrain.storageGB)
        let saved = try model.store.load().first { $0.id == id }!
        precondition(saved.relay?.storageLimitBytes == TorrentRelayDrain.storageGB)
        await model.refresh()
        precondition(model.job(id)?.phase == .downloading && model.gids[id] == gid)
        precondition(model.job(id)?.relay?.selection == [1], "Lowering a running limit must stop other partial files growing")
        let preserved = try Data(contentsOf: payload.appendingPathComponent(files[2].0))
        precondition(preserved == marker, "Deselection must preserve partial bytes")
        model.setStorageLimit(id, bytes: nil); await model.refresh()
        precondition(model.job(id)?.relay?.selection?.count == 20, "Raising a live limit must admit waiting files immediately")
        print("PASS live storage setting: custom limit persists, same torrent shrinks without deleting partials, automatic mode expands immediately")
    }

    @MainActor static func storageLimitRestart() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let mib: UInt64 = 1024 * 1024
        let files: [(String, UInt64)] = [("Examples/one", 64 * mib), ("Examples/two", 64 * mib), ("Examples/next", 8 * mib)]
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, _, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        await model.switchRelayToStorage(id, parent: root)
        try await until("restart limit fixture ready") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        await model.pauseRelay(id, automatic: true)
        let payload = model.job(id)!.relay!.payload!
        try LocalTorrentStore.protect(payload.appendingPathComponent("Examples"))
        for file in files.prefix(2) { try Data(repeating: 0x71, count: Int(file.1)).write(to: payload.appendingPathComponent(file.0)) }
        cloud.receipts = [1, 2]
        model.edit(id) {
            $0.completed = 128 * mib; $0.relay?.uploaded = [1, 2]; $0.relay?.selection = [1, 2]
            $0.relay?.storageLimitBytes = 96 * mib // Scaled fixture, below the UI's 1 GB minimum.
        }
        try model.save(); model.shutdown()
        let engine = TorrentFixtureEngine(); engine.files = files
        let next = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: model.store.directory, engine: engine, ram: ram)
        defer { next.shutdown() }
        next.relayContextProvider = { context }; next.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        await next.resumeRestoredTransfers()
        try await until("over-limit saved cache resumes") { next.job(id)?.phase == .downloading && !next.busy.contains(id) }
        precondition(next.job(id)?.relay?.selection == [3] && cloud.uploads.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[0].0).path))
        precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[1].0).path),
                     "Startup must clear enough confirmed copies to admit work, preserving the rest of the cache")
        print("PASS over-limit restart: confirmed cache shrinks before admission, next file starts, receipts prevent duplicate uploads")
    }

    @MainActor static func relayStorageCapacity() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, _, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud)
        defer { model.shutdown() }
        precondition(model.job(id)?.relay?.selection == [1, 2], "RAM must keep its original ceiling")
        await model.switchRelayToStorage(id, parent: root)
        try await until("storage uses space beyond the RAM ceiling") {
            model.job(id)?.phase == .downloading && !model.busy.contains(id)
        }
        let state = model.job(id)!.relay!
        precondition(state.selection == [1, 2, 3], "Storage must admit more than the former 256 MiB RAM window")
        precondition(state.memoryBytes == 256 * 1024 * 1024 && state.admissionBudget == nil)
        precondition(state.bufferAvailable != nil && state.bufferCapacity > state.memoryBytes)
        precondition(ram.volumes.isEmpty)
        // An older storage queue has no free-space snapshot and still carries
        // its old RAM size. Restart must measure the drive again, not freeze it.
        await model.pauseRelay(id, automatic: true)
        model.edit(id) { $0.relay?.bufferAvailable = nil }
        try model.save()
        model.shutdown()
        let engine = TorrentFixtureEngine(); engine.files = [
            ("Examples/one", 104_857_600), ("Examples/two", 104_857_600), ("Examples/three", 104_857_600)
        ]
        let next = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("State"), engine: engine, ram: ram)
        defer { next.shutdown() }
        next.relayContextProvider = { context }; next.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        await next.resumeRestoredTransfers()
        try await until("storage capacity remeasured after restart") { next.job(id)?.phase == .downloading && !next.busy.contains(id) }
        precondition(next.job(id)?.relay?.selection == [1, 2, 3] && next.job(id)?.relay?.bufferAvailable != nil)
        precondition(ram.volumes.isEmpty)
        print("PASS storage capacity: switching and restarting exceed the old RAM limit using measured drive space")
    }

    @MainActor static func relayStorageRecovery() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let files: [(String, UInt64)] = [("Examples/one", 1000), ("Examples/two", 1000)]
        let (model, _, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        await model.pause(id)
        let volume = model.job(id)!.relay!.volume!
        try LocalTorrentStore.protect(volume.payload.appendingPathComponent("Examples"))
        for file in files { try Data(repeating: 7, count: Int(file.1)).write(to: volume.payload.appendingPathComponent(file.0)) }
        model.edit(id) { $0.relay?.downloadedBytes = 1500 }
        await model.switchRelayToStorage(id, parent: root)
        let storage = model.job(id)!.relay!.storage!
        precondition(model.job(id)?.phase == .paused, "Switching a paused torrent must leave it paused")
        await model.stop(id)
        precondition(model.job(id)?.phase == .stopped && model.job(id)?.downloadedBytes == 1500)
        precondition(FileManager.default.fileExists(atPath: storage.payload.appendingPathComponent(files[0].0).path))
        model.shutdown()
        let engine = TorrentFixtureEngine(); engine.files = files
        let next = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root.appendingPathComponent("State"), engine: engine, ram: ram)
        defer { next.shutdown() }
        next.relayContextProvider = { context }; next.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        next.relayFlushWait = 0; next.relayFileCensusInterval = 0
        // A disconnected/replaced disk must pause without silently using RAM.
        let held = root.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: storage.root, to: held)
        await next.resume(id)
        try await until("missing storage rejected") { next.job(id)?.phase == .failed && next.relayTasks[id] == nil }
        precondition(ram.volumes.isEmpty && next.gids[id] == nil && !FileManager.default.fileExists(atPath: storage.root.path))
        try FileManager.default.moveItem(at: held, to: storage.root)
        await next.resume(id)
        try await until("storage restored after relaunch") { next.job(id)?.phase == .downloading && !next.busy.contains(id) }
        let gid = next.gids[id]!
        precondition(engine.directories[gid] == storage.payload && ram.volumes.isEmpty)
        engine.setFileProgress(gid, [1: 1000, 2: 500]); await next.refresh()
        try await until("shared-piece file uploaded") { next.job(id)?.relay?.uploaded == [1] && next.relayTasks[id] == nil }
        await next.refresh()
        precondition(FileManager.default.fileExists(atPath: storage.payload.appendingPathComponent(files[0].0).path), "Keep pieces shared with an unfinished selected file")
        try await completeRelayBatch(next, engine: engine, id: id)
        try await until("storage transfer complete") { next.job(id)?.phase == .completed }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: storage.payload.path)
        precondition(remaining.isEmpty && cloud.uploads == [1, 2] && next.job(id)?.completed == 2000)
        print("PASS storage recovery: paused/stop retain partials; relaunch uses original disk; missing disk rejected; shared pieces kept until safe; final payload removed")
    }

    @MainActor static func relayStorageFailures() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, _, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud, files: [("one", 1000)])
        defer { model.shutdown() }
        let volume = model.job(id)!.relay!.volume!
        await model.switchRelayToStorage(id, parent: volume.payload)
        precondition(model.job(id)?.relay?.storage == nil && model.job(id)?.phase == .downloading)
        let outside = root.appendingPathComponent("outside")
        try Data(repeating: 3, count: 1000).write(to: outside)
        let source = volume.payload.appendingPathComponent("one")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        await model.switchRelayToStorage(id, parent: root)
        precondition(model.job(id)?.relay?.storage == nil && ram.released == 0 && model.job(id)?.phase == .paused)
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("MyCloudDriver-Torrent-") }
        precondition(copies.isEmpty, "Incomplete copy should be cleaned while RAM remains intact")
        try FileManager.default.removeItem(at: source)
        try Data(contentsOf: outside).write(to: source)
        ram.failRelease = true
        await model.switchRelayToStorage(id, parent: root)
        precondition(model.job(id)?.relay?.storage != nil && model.job(id)?.relay?.volume != nil && ram.released == 0)
        let saved = try model.store.load().first { $0.id == id }!
        precondition(saved.relay?.storage != nil && saved.relay?.volume != nil, "Interrupted RAM release must leave a recoverable durable disk copy")
        ram.failRelease = false
        await model.resume(id)
        try await until("retry releases RAM and uses storage") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        precondition(ram.released == 1 && model.job(id)?.relay?.volume == nil)
        let kept = try Data(contentsOf: model.job(id)!.relay!.storage!.payload.appendingPathComponent("one"))
        precondition(kept == Data(repeating: 3, count: 1000))
        await model.stop(id)
        print("PASS storage failures: nested RAM destination and symlink copy rejected; RAM retained on failure; interrupted release recovered without losing either copy")
    }

    static func slidingAdmission() {
        let mib: UInt64 = 1024 * 1024
        let files = drainFiles(Array(repeating: 100 * mib, count: 5))
        func admit(_ active: Set<Int>, _ uploaded: Set<Int> = [], _ available: UInt64 = 256 * 1024 * 1024,
                   _ progress: [Int: UInt64] = [:]) -> TorrentRelayDrain.Admission {
            TorrentRelayDrain.admit(files: files, wanted: [1, 2, 3, 4, 5], uploaded: uploaded,
                active: active, progress: progress, available: available, budget: 256 * mib, pieceLength: 16_384)
        }
        precondition(admit([]).selection == [1, 2])
        precondition(admit([2], [1]).selection == [2, 3])
        precondition(admit([1, 2], [], 256 * mib, [1: 90 * mib, 2: 90 * mib]).selection == [1, 2],
                     "Partly downloaded sparse files still reserve their full lengths")
        precondition(admit([], [], 110 * mib).selection.isEmpty, "Actual free space must cover the reserve too")
        precondition(admit([2], [1], 110 * mib, [2: 50 * mib]).selection == [2])
        func disk(_ available: UInt64, active: Set<Int> = [], progress: [Int: UInt64] = [:]) -> TorrentRelayDrain.Admission {
            TorrentRelayDrain.admit(files: files, wanted: [1, 2, 3, 4, 5], uploaded: [], active: active,
                progress: progress, available: available, budget: nil, pieceLength: 16_384)
        }
        precondition(disk(530 * mib).selection == [1, 2, 3, 4, 5], "Storage must not inherit RAM's fixed or 85% ceiling")
        precondition(disk(250 * mib).selection == [1, 2] && disk(250 * mib).blockedOnSpace)
        precondition(disk(110 * mib, active: [1, 2], progress: [1: 90 * mib, 2: 90 * mib]).selection == [1, 2],
                     "Storage must reserve unfinished bytes before admitting another file")
        precondition(disk(140 * mib, active: [1, 2], progress: [1: 90 * mib, 2: 90 * mib]).selection == [1, 2, 3],
                     "Storage should expand when more drive space becomes available")
        precondition(disk(16 * mib).selection.isEmpty, "Keep filesystem and torrent overhead even without a RAM ceiling")
        let largeFile = drainFiles([300 * mib])
        precondition(TorrentRelayDrain.admit(files: largeFile, wanted: [1], uploaded: [], active: [], progress: [:],
            available: 350 * mib, budget: nil, pieceLength: 16_384).selection == [1], "A storage file may exceed the former RAM buffer")
        let frontier = TorrentRelayDrain.Layout(files: drainFiles([700, 700]), pieceLength: 1000)
        precondition(TorrentRelayDrain.removable(layout: frontier, complete: [1], committed: [1], removed: [], active: [1]) == [1],
                     "An unadmitted neighbour cannot pin the saved frontier")
        precondition(TorrentRelayDrain.removable(layout: frontier, complete: [1], committed: [1], removed: [], active: [2]).isEmpty,
                     "An active incomplete neighbour must retain its shared bytes")
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 1, waiting: 0, windowComplete: false, blockedOnSpace: true))
        let gib: UInt64 = 1024 * mib
        func advance(_ remaining: UInt64, _ reclaimable: UInt64, _ used: UInt64, pending: Bool = true) -> Bool {
            TorrentRelayDrain.shouldAdvanceWindow(hasPendingFiles: pending, remainingBytes: remaining,
                reclaimableBytes: reclaimable, used: used, capacity: 48 * gib)
        }
        precondition(!advance(32 * gib, 22 * mib, 7 * gib), "A small upload must not reset a healthy large window")
        precondition(advance(12 * gib, 22 * mib, 7 * gib), "Refill before admitted work runs out")
        precondition(advance(32 * gib, 6 * gib, 7 * gib), "A substantial release should slide the window")
        precondition(advance(32 * gib, 22 * mib, 36 * gib), "Memory pressure must still reclaim promptly")
        precondition(advance(0, 22 * mib, 7 * gib), "A finished window must not stall")
        precondition(!advance(gib, 2 * gib, 7 * gib, pending: false), "The final window need not reconnect to deselect uploads")
        // Thousands of adjacent small files share boundary reservations.
        let tiny = drainFiles(Array(repeating: 1000, count: 20_000))
        precondition(TorrentRelayDrain.admit(files: tiny, wanted: Set(1...20_000), uploaded: [], active: [], progress: [:],
            available: 4 * 1024 * mib, budget: 4 * 1024 * mib, pieceLength: 16 * mib).selection.count == tiny.count)
        print("PASS admission: full reservations, actual free space, frontier release, backpressure and large manifests")
    }

    static func downloadEstimates() {
        var job = LocalTorrentJob(id: UUID(), name: "Synthetic progress", phase: .downloading)
        job.total = 1000; job.completed = 250; job.downloadSpeed = 25
        precondition(job.downloadProgress == 0.25 && job.downloadETA == 30)
        job.phase = .paused; precondition(job.downloadETA == nil && job.downloadEstimate == "Paused")
        job.phase = .downloading; job.downloadSpeed = 0; precondition(job.downloadETA == nil)
        job.relay = TorrentRelayState(identity: UUID(), accountID: "fixture", credentialKind: .desktopOAuth,
            accountName: "Synthetic", parentID: "", parentName: "", rootName: "", memoryBytes: 256 * 1024 * 1024, batches: [])
        job.relay?.downloadedBytes = 750; job.downloadSpeed = 25
        precondition(job.downloadProgress == 0.75 && job.downloadETA == 10 && job.progress == 0.25,
                     "Download progress and saved-to-PikPak progress must stay distinct")
        job.relay?.downloadedBytes = 2000
        precondition(job.downloadProgress == 1 && job.downloadETA == nil)
        print("PASS progress: download percentage and ETA, uploads, pauses, stalls and bounded totals")
    }

    @MainActor static func automaticTorrentResume() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (first, engine, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud)
        first.edit(id) {
            $0.relay?.downloadedBytes = 4096
            // A shipping queue has no sliding selection key. Keep its current
            // batch's partial files when upgrading and auto-resuming.
            $0.relay?.selection = nil
        }
        await first.pauseRelay(id, automatic: true)
        let uuid = first.job(id)?.relay?.volume?.uuid
        first.shutdown()
        let nextEngine = TorrentFixtureEngine(); nextEngine.files = engine.files
        let next = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: first.store.directory, engine: nextEngine, ram: ram)
        defer { next.shutdown() }
        next.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        next.relayContextProvider = { relayContext(account: "different-account") }
        await next.resumeRestoredTransfers()
        try await until("download resumes without its PikPak login") { next.job(id)?.phase == .downloading && next.relayTasks[id] == nil }
        precondition(nextEngine.running && next.job(id)?.relay?.uploadFailure?.awaitingAccount == true)
        let calls = cloud.invocations
        // Returning credentials must bypass even a recently completed census;
        // routine energy-saving throttles cannot defer upload recovery.
        next.relayFileCensusAt[id] = Date(); next.relayFileCensusInterval = 3600
        next.relayContextProvider = { context }
        await next.refresh()
        try await until("automatic upload recovery after sign-in") { next.job(id)?.relay?.uploadFailure == nil && next.relayTasks[id] == nil }
        precondition(cloud.invocations == calls + 1)
        precondition(next.job(id)?.relay?.volume?.uuid == uuid && next.job(id)?.downloadedBytes == 4096)
        await next.pause(id); await next.resumeRestoredTransfers()
        precondition(next.job(id)?.phase == .paused, "A new pause must hold for the rest of this app session")
        let held = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: next.store.directory, engine: TorrentFixtureEngine(), ram: ram)
        await held.resumeRestoredTransfers()
        precondition(held.job(id)?.automaticallyResume == false && held.restoredResumeIDs.isEmpty,
                     "An explicit pause must also survive an app restart")
        held.shutdown()
        await next.stop(id); next.shutdown()
        let stopped = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: first.store.directory, engine: TorrentFixtureEngine(), ram: ram)
        defer { stopped.shutdown() }
        stopped.relayContextProvider = { context }
        await stopped.resumeRestoredTransfers()
        precondition(stopped.job(id)?.phase == .stopped && stopped.restoredResumeIDs.isEmpty)
        print("PASS automatic resume: saved pieces without cloud login, uploads recover after sign-in, explicit pause and Stop")
    }

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
        var progress: [Int: UInt64] = [:]
        for file in model.job(id)!.files where model.job(id)!.relay!.selection!.contains(file.index) { progress[file.index] = file.length }
        engine.setFileProgress(gid, progress)
        model.relayFileCensusAt[id] = nil
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
        try await until("upload failure keeps downloading") { first.job(id)?.phase == .downloading && first.job(id)?.relay?.uploadFailure != nil && first.relayTasks[id] == nil }
        precondition(first.job(id)?.relay?.uploaded == [1] && cloud.uploads == [1])
        first.shutdown(); first.shutdown()
        // Cloud accepted another file, but its UI event was lost; a Mac restart
        // then discards all RAM. Only file 3 must be fetched again.
        cloud.receipts.insert(2); ram.volumes.removeAll()
        let nextEngine=TorrentFixtureEngine();nextEngine.files=engine.files
        let next=LocalTorrentModel(dnsProbe: { _ in .clean }, directory:first.store.directory,engine:nextEngine,ram:ram)
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
    @MainActor static func relayCloudOutage() async throws {
        for storageMode in [false, true] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
            let files: [(String, UInt64)] = [("Examples/one", 32768), ("Examples/two", 32768), ("Examples/three", 32768)]
            let (model, engine, id, context) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
            defer { model.shutdown() }
            if storageMode {
                await model.switchRelayToStorage(id, parent: root)
                try await until("storage ready for cloud outage") { model.job(id)?.phase == .downloading && model.relayTasks[id] == nil }
            }
            model.relayFileCensusInterval = 0; model.relayFlushWait = 0
            let gid = model.gids[id]!, payload = model.job(id)!.relay!.payload!
            try LocalTorrentStore.protect(payload.appendingPathComponent("Examples"))
            for file in files { try Data(repeating: 0x71, count: Int(file.1)).write(to: payload.appendingPathComponent(file.0)) }
            let pauses = engine.pauses.count, begins = engine.begun.count
            cloud.offline = true
            engine.setFileProgress(gid, [1: 32768, 2: 4096])
            await model.refresh()
            try await until("cloud outage only defers upload") { model.job(id)?.relay?.uploadFailure != nil && model.relayTasks[id] == nil }
            precondition(model.job(id)?.phase == .downloading && engine.pauses.count == pauses && engine.begun.count == begins)
            let downloaded = model.job(id)!.downloadedBytes, attempts = cloud.invocations
            engine.setFileProgress(gid, [1: 32768, 2: 16384, 3: 4096])
            engine.states[gid]?["downloadSpeed"] = "8192"
            for _ in 0..<8 { await model.refresh() }
            precondition(model.job(id)!.downloadedBytes > downloaded && model.job(id)?.downloadSpeed == 8192)
            precondition(cloud.invocations == attempts && model.gids[id] == gid && cloud.uploads.isEmpty,
                         "Backoff must leave the existing torrent running without repeatedly launching the cloud helper")
            for file in files { precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent(file.0).path)) }
            let saved = try model.store.load().first { $0.id == id }
            precondition(saved?.relay?.uploadFailure != nil && saved?.phase == .paused,
                         "A restored queue retains the upload outage and prepares the download for automatic resume")

            // A failed response after a real commit must not cause a duplicate
            // upload when the automatic retry checks durable cloud receipts.
            cloud.offline = false; cloud.loseCommitReply = true
            func allowRetry() {
                model.edit(id) { $0.relay?.uploadFailure = .init(message: "Synthetic outage", retryAt: .distantPast, awaitingAccount: false) }
            }
            allowRetry(); await model.refresh()
            try await until("commit reply lost while torrent continues") { cloud.uploads == [1] && model.job(id)?.relay?.uploadFailure != nil && model.relayTasks[id] == nil }
            precondition(model.job(id)?.relay?.uploaded.isEmpty == true && model.job(id)?.phase == .downloading)
            precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent(files[0].0).path))
            allowRetry(); await model.refresh()
            try await until("receipt recovered automatically") { model.job(id)?.relay?.uploaded == [1] && model.job(id)?.relay?.uploadFailure == nil && model.relayTasks[id] == nil }
            precondition(cloud.uploads == [1] && engine.pauses.count == pauses && engine.begun.count == begins)

            model.relayContextProvider = { nil }
            await model.refresh()
            precondition(model.job(id)?.phase == .downloading && model.job(id)?.relay?.uploadFailure?.awaitingAccount == true)
            engine.setFileProgress(gid, [1: 32768, 2: 32768, 3: 32768])
            await model.refresh()
            precondition(model.job(id)?.downloadProgress == 1 && model.job(id)?.phase == .downloading && cloud.uploads == [1])
            for file in files.dropFirst() { precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent(file.0).path)) }
            await model.pause(id)
            let pausedCalls = cloud.invocations
            model.relayContextProvider = { context }
            await model.refresh()
            precondition(model.job(id)?.phase == .paused && cloud.invocations == pausedCalls)
            await model.resume(id)
            try await until("pending files upload after original account returns") { model.job(id)?.phase == .completed }
            precondition(cloud.uploads == [1, 2, 3] && model.job(id)?.relay?.uploadFailure == nil)
            if storageMode {
                let remaining = try FileManager.default.contentsOfDirectory(atPath: payload.path)
                precondition(remaining.isEmpty)
            } else { precondition(ram.volumes.isEmpty) }
        }
        print("PASS PikPak outage: RAM/storage downloads continue, bounded retries, files retained, lost commits reconciled, sign-in recovery and manual Pause")
    }

    @MainActor static func relayOfflineFullBuffer() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud)
        defer { model.shutdown() }
        let payload = model.job(id)!.relay!.payload!
        let pauses = engine.pauses.count, begins = engine.begun.count
        ram.availableOverride = 8 * 1024 * 1024; cloud.offline = true
        try await completeRelayBatch(model, engine: engine, id: id)
        try await until("full buffer retains pending uploads") { model.job(id)?.relay?.uploadFailure != nil && model.relayTasks[id] == nil }
        precondition(model.job(id)?.phase == .downloading && model.job(id)?.relay?.waitingForUploadSpace == true)
        precondition(model.job(id)?.relay?.selection == [1, 2] && model.job(id)?.relay?.payload == payload)
        precondition(engine.pauses.count == pauses && engine.begun.count == begins && cloud.uploads.isEmpty)
        await model.stop(id)
        cloud.offline = false
        let calls = cloud.invocations
        await model.refresh(); await model.resumeRestoredTransfers()
        precondition(model.job(id)?.phase == .stopped && cloud.invocations == calls)
        print("PASS offline full buffer: no oversized admission or disk fallback, pending files retained, explicit Stop stays stopped")
    }

    @MainActor static func relayPauseDuringRecovery() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud,
            files: [("Examples/one", 32768), ("Examples/two", 32768)])
        defer { model.shutdown() }
        model.relayFileCensusInterval = 0; model.relayFlushWait = 0
        cloud.offline = true
        try await completeRelayBatch(model, engine: engine, id: id)
        try await until("upload retry scheduled") { model.job(id)?.relay?.uploadFailure != nil && model.relayTasks[id] == nil }
        cloud.offline = false; cloud.blockReconcile = true
        model.edit(id) { $0.relay?.uploadFailure = .init(message: "Synthetic outage", retryAt: .distantPast, awaitingAccount: false) }
        await model.refresh()
        try await until("cloud recovery check started") { model.relayUploaders[id] != nil }
        await model.pause(id)
        let calls = cloud.invocations
        cloud.blockReconcile = false
        try await until("in-flight recovery check returns while paused") { model.relayUploaders[id] == nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(model.job(id)?.phase == .paused && cloud.invocations == calls && cloud.uploads.isEmpty)
        await model.resume(id)
        try await until("explicit Resume uploads recovered files") { model.job(id)?.phase == .completed }
        precondition(cloud.uploads == [1, 2])
        print("PASS cloud retry controls: Pause during receipt reconciliation prevents the next upload until Resume")
    }

    /// A dropped status reply is not a failed transfer. A local download just
    /// reconnects; a relay used to pause the whole transfer on the first one.
    /// BitTorrent is reciprocal: a peer that gives nothing back gets choked,
    /// so a download to this Mac seeds at a rate worth reciprocating. A relay
    /// is the opposite — peer upload and the PikPak upload share one uplink,
    /// and only the PikPak upload returns RAM — so it seeds far more modestly.
    @MainActor static func uploadLimits() async throws {
        let root=try temporary();defer{try? FileManager.default.removeItem(at:root)}
        let ram=RelayFixtureRAM(),cloud=RelayFixtureCloud()
        let (relay,engine,id,_)=try await startRelay(root:root,ram:ram,cloud:cloud)
        defer { relay.shutdown() }
        precondition(engine.limits[relay.gids[id]!] == Aria2TorrentEngine.relayUploadLimit,
                     "A RAM relay must leave its uplink to the PikPak upload")
        let other=try temporary();defer{try? FileManager.default.removeItem(at:other)}
        let localEngine=TorrentFixtureEngine()
        let (local,localID)=try await prepared(root:other,engine:localEngine)
        defer { local.shutdown() }
        await local.download(localID, selected: [2], to: other)
        precondition(local.job(localID)?.phase == .downloading)
        precondition(localEngine.limits[local.gids[localID]!] == nil,
                     "A download to this Mac seeds under the shared ceiling, not a private cap")
        print("PASS upload limits: a relay yields its uplink to PikPak; a local download seeds for reciprocation")
    }

    @MainActor static func relayStatusHiccup() async throws {
        let root=try temporary();defer{try? FileManager.default.removeItem(at:root)}
        let ram=RelayFixtureRAM(),cloud=RelayFixtureCloud()
        let (model,engine,id,_)=try await startRelay(root:root,ram:ram,cloud:cloud,files:[("Example/one",1000),("Example/two",1000)])
        defer { model.shutdown() }
        engine.statusFailures = 2
        await model.refresh(); await model.refresh()
        precondition(model.job(id)?.phase == .downloading, "A dropped status reply must not pause a running relay")
        precondition(model.job(id)?.message == "Reconnecting to download status…", "The card must say it is reconnecting")
        precondition(model.job(id)?.downloadSpeed == 0, "A rate nobody reported must not be shown")
        engine.statusFailures = 0
        await model.refresh()
        precondition(model.job(id)?.message.hasPrefix("Downloading ") == true, "A recovered status returns the batch line")
        engine.statusFailures = 99
        for _ in 0..<model.statusRetries { await model.refresh() }
        precondition(model.job(id)?.phase == .paused, "Repeated non-transport errors must pause the transfer")
        print("PASS RAM relay: a dropped status reply reconnects; repeated non-transport engine errors still pause safely")
    }

    @MainActor static func relayConnectionRecovery() async throws {
        for storage in [false, true] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
            let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud)
            defer { model.shutdown() }
            if storage {
                await model.switchRelayToStorage(id, parent: root)
                try await until("storage resumes before connection checks") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
            }
            model.censusInterval = 0
            let gid = model.gids[id]!, starts = engine.begun.count, pauses = engine.pauses.count
            let selection = model.job(id)?.relay?.selection
            engine.connectedPeers = 2
            engine.states[gid]?["connections"] = "2"; engine.states[gid]?["downloadSpeed"] = "65536"
            await model.refreshRelay(id)
            for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet] {
                engine.statusFailureError = URLError(code); engine.statusFailures = 30
                for _ in 0..<12 { await model.refreshRelay(id) }
                precondition(model.job(id)?.phase == .downloading && engine.states[gid]?["status"] as? String == "active")
                precondition(model.gids[id] == gid && model.job(id)?.relay?.selection == selection)
                precondition(engine.pauses.count == pauses && engine.begun.count == starts,
                             "Repeated missing status replies must never disconnect a working torrent")
                precondition(model.job(id)?.peers == 0 && model.connectedPeers(id).isEmpty,
                             "An extended status outage must stop displaying stale peers")
                engine.statusFailures = 0
                await model.refreshRelay(id)
                precondition(model.job(id)?.downloadSpeed == 65536 && model.job(id)?.peers == 2 && model.statusFailures[id] == nil)
            }
            // A quiet swarm stays live, then recovers without Pause/Resume.
            engine.connectedPeers = 0
            engine.states[gid]?["connections"] = "0"; engine.states[gid]?["downloadSpeed"] = "0"
            model.edit(id) { $0.stalledSince = Date().addingTimeInterval(-3600) }
            for _ in 0..<12 { await model.refreshRelay(id) }
            precondition(model.job(id)?.phase == .downloading && engine.pauses.count == pauses && engine.begun.count == starts)
            engine.connectedPeers = 2
            engine.states[gid]?["connections"] = "2"; engine.states[gid]?["downloadSpeed"] = "65536"
            await model.refreshRelay(id)
            precondition(model.job(id)?.downloadSpeed == 65536 && model.job(id)?.peers == 2)
            // A cloud upload can keep progressing while its torrent status is unavailable.
            model.edit(id) { $0.phase = .uploading; $0.relayUploadSpeed = 123; $0.message = "Synthetic upload" }
            engine.statusFailures = 30
            for _ in 0..<12 { await model.refreshRelay(id) }
            precondition(model.job(id)?.phase == .uploading && model.job(id)?.relayUploadSpeed == 123)
            precondition(model.job(id)?.message == "Synthetic upload" && engine.pauses.count == pauses)
            await model.pause(id)
            engine.statusFailures = 0
            for _ in 0..<3 { await model.refresh() }
            precondition(model.job(id)?.phase == .paused && engine.begun.count == starts,
                         "Recovery must respect an explicit Pause")
            await model.stop(id)
            precondition(model.job(id)?.phase == .stopped)
        }
        print("PASS connection recovery: RAM/storage survive long transport outages and empty swarms, resume telemetry automatically, preserve cloud uploads and respect Pause/Stop")
    }

    /// A drain uploads finished files while the torrent keeps running, so the
    /// card must keep reporting the swarm rather than freezing until it ends.
    @MainActor static func relayDrainTelemetry() async throws {
        let root=try temporary();defer{try? FileManager.default.removeItem(at:root)}
        let ram=RelayFixtureRAM(),cloud=RelayFixtureCloud()
        let (model,engine,id,_)=try await startRelay(root:root,ram:ram,cloud:cloud,files:[("Example/one",1000),("Example/two",1000)])
        defer { model.shutdown() }
        guard let gid=model.gids[id] else { preconditionFailure("missing RAM gid") }
        model.censusInterval = 0
        engine.connectedPeers = 2
        engine.peerDetail = [.init(address:"198.51.100.3:6881", downloadSpeed:1024, uploadSpeed:64, seeder:false)]
        engine.states[gid]?["downloadSpeed"]="8192"; engine.states[gid]?["uploadSpeed"]="256"
        engine.states[gid]?["connections"]="6"; engine.states[gid]?["completedLength"]="700"
        // A drain: the uploader owns the phase while aria2 keeps downloading.
        model.edit(id) { $0.phase = .uploading; $0.message = "Uploading Example/one" }
        await model.refresh()
        guard let job=model.job(id) else { preconditionFailure("missing relay job") }
        precondition(job.downloadSpeed == 8192 && job.uploadSpeed == 256, "A drain must not freeze the torrent's own rates")
        precondition(job.relay?.batchDownloaded == 700 && job.peers == 2)
        precondition(job.message == "Uploading Example/one", "Torrent telemetry must not overwrite the upload line")
        precondition(!model.connectedPeers(id).isEmpty, "The swarm is still there while a finished file uploads")
        // The batch state machine belongs to the downloading phase alone.
        engine.states[gid]?["status"]="complete"
        await model.refresh()
        precondition(model.job(id)?.phase == .uploading && model.gids[id] == gid, "A drain must not advance the batch")
        print("PASS RAM relay: a drain keeps the torrent's telemetry live without touching the batch state machine")
    }

    /// A relay job keeps seeding while it fills RAM, so its card must report
    /// what goes out to peers without confusing it with the PikPak upload.
    @MainActor static func relaySpeeds() async throws {
        let root=try temporary();defer{try? FileManager.default.removeItem(at:root)}
        let ram=RelayFixtureRAM(),cloud=RelayFixtureCloud()
        let (model,engine,id,_)=try await startRelay(root:root,ram:ram,cloud:cloud,files:[("Example/one",1000),("Example/two",1000)])
        defer { model.shutdown() }
        guard let gid=model.gids[id] else { preconditionFailure("missing RAM gid") }
        engine.states[gid]?["downloadSpeed"]="4096"; engine.states[gid]?["uploadSpeed"]="512"
        engine.states[gid]?["connections"]="2"; engine.states[gid]?["numSeeders"]="1"
        await model.refresh()
        guard let job=model.job(id) else { preconditionFailure("missing relay job") }
        precondition(job.downloadSpeed == 4096 && job.uploadSpeed == 512, "A RAM relay must report what it sends to peers")
        precondition((job.relayUploadSpeed ?? 0) == 0, "Peer seeding is not a PikPak upload")
        await model.pause(id)
        precondition(model.job(id)?.uploadSpeed == 0 && model.job(id)?.relayUploadSpeed == nil, "A paused relay uploads to nobody")
        precondition(model.job(id)?.downloadSpeed == 0)
        print("PASS RAM relay: peer upload speed reported beside the download and kept apart from the PikPak rate")
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
        // The login method may change mid-transfer; the PikPak account may not.
        model.relayContextProvider={relayContext(identity:UUID(),account:"other-account",kind:.desktopOAuth)}
        await model.resume(id)
        try await until("download resumes with cloud upload held") { model.job(id)?.phase == .downloading && model.job(id)?.relay?.uploadFailure?.awaitingAccount == true && model.relayTasks[id] == nil }
        precondition(cloud.invocations == calls && cloud.uploads.isEmpty)
        model.relayContextProvider={context};await model.refresh()
        try await until("upload recovers under the original account") { model.job(id)?.phase == .completed }
        precondition(cloud.invocations > calls && cloud.uploads == [1,2])
        model.shutdown()
        let root2=try temporary();defer{try? FileManager.default.removeItem(at:root2)}
        let (retry,engine2,id2,context2)=try await startRelay(root:root2,ram:ram,cloud:RelayFixtureCloud())
        let original=retry.job(id2)?.relay?.volume?.uuid
        retry.relayContextProvider={relayContext(account:"other-account")}
        await retry.refresh()
        precondition(retry.job(id2)?.phase == .downloading && retry.job(id2)?.relay?.uploadFailure?.awaitingAccount == true)
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
            let held = volume.root.appendingPathComponent("held-payload")
            let outside = root.appendingPathComponent("OutsideRAM")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: volume.payload, to: held)
            try FileManager.default.createSymbolicLink(at: volume.payload, withDestinationURL: outside)
            do { try await driver.validate(volume); preconditionFailure("A payload link to disk was accepted") } catch {}
            try FileManager.default.removeItem(at: volume.payload)
            try FileManager.default.moveItem(at: held, to: volume.payload)
            try await driver.validate(volume)
            let sparse=volume.payload.appendingPathComponent("sparse.bin")
            FileManager.default.createFile(atPath:sparse.path,contents:nil)
            let handle=try FileHandle(forWritingTo:sparse);try handle.seek(toOffset:10 * 1024 * 1024 * 1024);try handle.write(contentsOf:Data("boundary".utf8));try handle.close()
            try await driver.clear(volume)
            let remaining = try FileManager.default.contentsOfDirectory(atPath:volume.payload.path)
            precondition(remaining.isEmpty)
            // A rejected payload must not prevent Stop from releasing owned RAM.
            try FileManager.default.removeItem(at: volume.payload)
            try FileManager.default.createSymbolicLink(at: volume.payload, withDestinationURL: outside)
            try await driver.release(volume)
            let outsideFiles = try FileManager.default.contentsOfDirectory(atPath: outside.path)
            precondition(outsideFiles.isEmpty)
            let permissions=try FileManager.default.attributesOfItem(atPath:volume.root.path)[.posixPermissions] as? NSNumber
            precondition(permissions?.intValue == 0o500)
            do { try Data("must not reach disk".utf8).write(to:volume.root.appendingPathComponent("test"));preconditionFailure("unmounted RAM path allowed disk writes") } catch {}
            do { try FileManager.default.createDirectory(at: volume.payload, withIntermediateDirectories: true); preconditionFailure("Lost RAM allowed a payload folder on disk") } catch {}
            try FileManager.default.removeItem(at:root)
            print("PASS real RAM disk: case-sensitive APFS, sparse boundary pieces, restart reuse, owned cleanup and disk-fallback prevention")
        } catch { try? await driver.release(volume);throw error }
    }
}

@MainActor final class RelayHashFixtureUpload: TorrentRelayUploading {
    let original: URL
    let ram: TorrentRAMDriving
    var hashes: [Int: SHA256.Digest] = [:]
    var offline = false
    var failedAttempts = 0
    /// How many files each non-reconcile upload carried. A batch smaller than
    /// the selection proves a file was saved before its batch finished.
    var batchesSent: [Int] = []
    init(original: URL, ram: TorrentRAMDriving) { self.original = original; self.ram = ram }
    func pause(_ paused: Bool) throws {}
    func stop() {}
    func run(request: [String: Any], directory: URL, context: PikPakManagementContext, event: @escaping ([String: Any]) -> Void) async throws {
        if offline { failedAttempts += 1; throw URLError(.networkConnectionLost) }
        if request["reconcile_only"] as? Bool == true { event(["event":"finished"]); return }
        batchesSent.append((request["files"] as! [[String: Any]]).count)
        let mount = URL(fileURLWithPath:request["ram_root"] as! String)
        let owner = UUID(uuidString: request["job_id"] as! String)!
        let jobs = try LocalTorrentStore(directory: directory.deletingLastPathComponent()).load()
        if let storage = jobs.first(where: { $0.id == owner })?.relay?.storage {
            try storage.validate(owner: owner)
            precondition(storage.payload.path == mount.path)
        } else {
            let volume = try JSONDecoder().decode(TorrentRAMVolume.self, from:Data(contentsOf:directory.appendingPathComponent("ram-volume.json")))
            try await ram.validate(volume)
        }
        for source in request["files"] as! [[String: Any]] {
            let path=source["path"] as! String,index=source["index"] as! Int
            let data=try Data(contentsOf:mount.appendingPathComponent(path))
            let reference=try Data(contentsOf:original.appendingPathComponent(path))
            let hash=SHA256.hash(data:data)
            precondition(hash == SHA256.hash(data:reference),"Torrent relay payload differs from the seed")
            hashes[index]=hash
            event(["event":"committed","index":index])
        }
        event(["event":"finished"])
    }
}
extension LocalTorrentTests {
    @MainActor static func actualPeerReconnect(_ fixture: URL) async throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let root = fixture.deletingLastPathComponent(), state = root.appendingPathComponent("RAMQueue")
        let options = ["enable-dht":"false", "enable-dht6":"false", "enable-peer-exchange":"false", "bt-enable-lpd":"false",
                       "listen-port":"\(config["leecher_port"] as! Int)", "max-overall-download-limit":"512K", "bt-tracker-interval":"1"]
        let ram = TorrentRAMDisk(), context = relayContext()
        let engine = fixtureEngine(executable: URL(fileURLWithPath: config["engine"] as! String),
                                       directory: state.appendingPathComponent("Engine"), extraOptions: options, trackers: [], mapsPorts: false)
        let model = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: state, engine: engine, ram: ram)
        let uploader = RelayHashFixtureUpload(original: root.appendingPathComponent("Seed"), ram: ram)
        model.relayContextProvider = { context }; model.relayUploaderFactory = { uploader }
        model.censusInterval = 0.5; model.relayFileCensusInterval = 0.5; model.relayFlushWait = 0
        defer { model.shutdown() }
        let id = try model.add(torrent: root.appendingPathComponent("fixture.torrent"))
        try await until("reconnect fixture metadata", seconds: 20) { model.job(id)?.phase == .choosing }
        await model.downloadToPikPak(id, selected: [1], context: context, accountName: "Synthetic PikPak",
                                   parentID: "fixture", parentName: "Fixture", memoryBytes: 256 * 1024 * 1024)
        do {
            try await until("initial peer download", seconds: 45) { (model.job(id)?.downloadedBytes ?? 0) > 0 && (model.job(id)?.peers ?? 0) > 0 }
            let gid = model.gids[id]!, volume = model.job(id)!.relay!.volume!
            var previous = model.job(id)!.downloadedBytes
            func stillRunning() {
                let job = model.job(id)!
                precondition(engine.running && model.gids[id] == gid && job.phase == .downloading)
                precondition(job.relay?.volume == volume && job.relay?.selection == [1] && job.checkingPieces != true)
                precondition(job.downloadedBytes >= previous, "A peer disconnect must retain verified progress")
                previous = job.downloadedBytes
            }
            for cycle in 1...2 {
                print("FIXTURE disconnect seeder \(cycle)")
                try await until("seeder disconnected", seconds: 15) { FileManager.default.fileExists(atPath: root.appendingPathComponent("seeder-disconnected-\(cycle)").path) }
                try await until("peer loss reaches the transfer", seconds: 20) { model.job(id)?.peers == 0 }
                for _ in 0..<8 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    await model.refresh(); stillRunning()
                }
                let before = previous
                print("FIXTURE reconnect seeder \(cycle)")
                try await until("seeder restarted", seconds: 20) { FileManager.default.fileExists(atPath: root.appendingPathComponent("seeder-reconnected-\(cycle)").path) }
                try await until("automatic peer reconnection", seconds: 90) {
                    stillRunning()
                    return model.job(id)!.downloadedBytes > before && model.job(id)!.downloadSpeed > 0 && model.job(id)!.peers > 0
                }
                print("PASS peer recovery \(cycle): same torrent and RAM buffer resume receiving without Pause/Resume or verification reset")
            }
            try await until("recovered torrent reaches upload sink", seconds: 80) { [.completed, .failed, .paused].contains(model.job(id)?.phase ?? .metadata) }
            guard model.job(id)?.phase == .completed else { throw LocalTorrentError.message(model.job(id)?.message ?? "Reconnect fixture failed") }
            precondition(Set(uploader.hashes.keys) == [1] && model.job(id)?.relay?.volume == nil)
            print("PASS repeated real peer loss: automatic recovery twice, monotonic progress, SHA-256 verified upload and final RAM release")
        } catch {
            await model.stop(id)
            throw error
        }
    }

    @MainActor static func actualRelay(_ fixture: URL) async throws {
        let config=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as! [String:Any]
        let root=fixture.deletingLastPathComponent(),state=root.appendingPathComponent("RAMQueue")
        let storageMode = config["storage"] as? Bool == true
        let uploadOutage = config["upload_outage"] as? Bool == true
        let rolling = config["rolling"] as? Bool == true || storageMode
        let options=["enable-dht":"false","enable-dht6":"false","enable-peer-exchange":"false","bt-enable-lpd":"false","listen-port":"\(config["leecher_port"] as! Int)","max-overall-download-limit":rolling ? "16M" : "128K","bt-tracker-interval":"2"]
        let executable=URL(fileURLWithPath:config["engine"] as! String),ram=TorrentRAMDisk(),context=relayContext()
        let uploader=RelayHashFixtureUpload(original:root.appendingPathComponent("Seed"),ram:ram)
        uploader.offline = uploadOutage
        func makeModel() -> LocalTorrentModel {
            let model=LocalTorrentModel(dnsProbe: { _ in .clean }, directory:state,engine:fixtureEngine(executable:executable,directory:state.appendingPathComponent("Engine"),extraOptions:options,trackers:[],mapsPorts:false),ram:ram)
            model.relayContextProvider={context};model.relayUploaderFactory={uploader}
            // The fixture torrent is far too small to reach the 3-minute or
            // 256 MB flush triggers, so upload every completed file at once.
            model.relayFlushWait=0; model.relayFileCensusInterval=0.5
            if uploadOutage { model.relayUploadRetryDelay = 0.5 }
            return model
        }
        let first=makeModel();let id=try first.add(magnet:config["magnet"] as! String)
        try await until("real RAM file list",seconds:45){first.job(id)?.phase == .choosing}
        // aria2 retains the original file paths even if `dir` later changes.
        // A stale metadata handle must be rejected before it can write payload.
        let diskFolder = state.appendingPathComponent("StaleHandle")
        let volume = try await ram.acquire(id: id, bytes: 256 * 1024 * 1024, directory: first.store.jobDirectory(id))
        let stale = try await first.engine.addTorrent(Data(contentsOf: root.appendingPathComponent("fixture.torrent")), directory: diskFolder, selection: [1])
        do { try await first.engine.beginRelay(stale, directory: volume.payload, selection: [1]); preconditionFailure("Real engine resumed a disk destination as RAM") }
        catch { precondition(error as? LocalTorrentError == .ramDestinationMismatch, error.localizedDescription) }
        let rejected = try await first.engine.status(stale, files: false)
        precondition(rejected.state == "paused" && rejected.completed == 0)
        precondition(!FileManager.default.fileExists(atPath: diskFolder.appendingPathComponent("FixtureFiles").path))
        try await first.engine.remove(stale)
        print("PASS real engine: a disk-bound torrent cannot resume as a RAM relay; no payload was written")
        await first.downloadToPikPak(id,selected:rolling ? [1,2,3] : [1,3],context:context,accountName:"Synthetic PikPak",parentID:"fixture",parentName:"Fixture",memoryBytes:256 * 1024 * 1024)
        do {
            try await until("real RAM torrent pieces",seconds:50){ ((first.job(id)?.relay?.batchDownloaded ?? 0) > 0 && !first.busy.contains(id)) || first.job(id)?.phase == .failed }
            guard first.job(id)?.phase.active == true, let activeGID = first.gids[id] else {throw LocalTorrentError.message(first.job(id)?.message ?? "RAM download failed")}
            let downloading = try await first.engine.status(activeGID, files: false)
            precondition(["active", "complete"].contains(downloading.state), "An upload retry must leave the actual torrent running")
            await first.pauseRelay(id, automatic: true)
            let uuid=first.job(id)?.relay?.volume?.uuid
            precondition(first.job(id)?.phase == .paused)
            first.shutdown();try await Task.sleep(nanoseconds:1_500_000_000)
            var next=makeModel();await next.resumeRestoredTransfers()
            try await until("RAM reuse after app restart",seconds:20){(next.job(id)?.phase.active == true && next.gids[id] != nil && !next.busy.contains(id)) || next.job(id)?.phase == .failed}
            precondition(next.job(id)?.relay?.volume?.uuid == uuid)
            if storageMode {
                await next.pause(id)
                let volume = next.job(id)!.relay!.volume!
                let checkpointURL = volume.payload.appendingPathComponent("FixtureFiles.aria2")
                let checkpoint = try? Data(contentsOf: checkpointURL)
                if executable.lastPathComponent == "mycloud-torrent" {
                    let saved = try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("Engine/Resume").path)
                    precondition(saved.contains { $0.hasSuffix(".json") }, "Native engine must checkpoint before relocation")
                } else { precondition(checkpoint != nil) }
                var payloadHashes: [String: SHA256Digest] = [:]
                let payloadPrefix = volume.payload.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                let payloadFiles = FileManager.default.enumerator(at: volume.payload, includingPropertiesForKeys: [.isRegularFileKey])!
                while let file = payloadFiles.nextObject() as? URL {
                    if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
                        precondition(canonical.hasPrefix(payloadPrefix))
                        let relative = String(canonical.dropFirst(payloadPrefix.count))
                        payloadHashes[relative] = SHA256.hash(data: try Data(contentsOf: file))
                    }
                }
                let storageParent = root.appendingPathComponent("Storage")
                try FileManager.default.createDirectory(at: storageParent, withIntermediateDirectories: false)
                await next.switchRelayToStorage(id, parent: storageParent)
                guard let storage = next.job(id)?.relay?.storage, next.job(id)?.phase == .paused else {
                    throw LocalTorrentError.message(next.error ?? "Real RAM → storage migration failed")
                }
                if let checkpoint {
                    let copied = try Data(contentsOf: storage.payload.appendingPathComponent("FixtureFiles.aria2"))
                    precondition(copied == checkpoint)
                }
                for (relative, expected) in payloadHashes {
                    let copied = try Data(contentsOf: storage.payload.appendingPathComponent(relative))
                    precondition(SHA256.hash(data: copied) == expected)
                }
                precondition(next.job(id)?.relay?.volume == nil)
                precondition(!FileManager.default.fileExists(atPath: volume.root.appendingPathComponent(".mycloud-owner").path))
                next.shutdown(); try await Task.sleep(nanoseconds: 1_500_000_000)
                next = makeModel(); await next.resume(id)
                try await until("real storage resume after app relaunch", seconds: 20) { (next.job(id)?.phase.active == true && next.gids[id] != nil && !next.busy.contains(id)) || next.job(id)?.phase == .failed }
                precondition(next.job(id)?.relay?.storage == storage && next.job(id)?.relay?.volume == nil)
                precondition(Set(next.job(id)?.relay?.selection ?? []).union(next.job(id)?.relay?.uploaded ?? []) == [1, 2, 3],
                             "Storage must admit the generated torrent beyond its former 256 MiB RAM ceiling")
                print("PASS real RAM → storage: partial data preserved, RAM detached and disk destination retained across relaunch")
            }
            let gid = next.gids[id]
            if uploadOutage {
                let initial = next.job(id)!.downloadedBytes
                try await until("all torrent bytes reach storage while PikPak is offline", seconds: 100) {
                    precondition(next.job(id)?.phase.active == true && next.gids[id] == gid)
                    precondition(uploader.hashes.isEmpty, "Offline cloud must never receive an upload")
                    return next.job(id)?.downloadProgress == 1 && next.relayTasks[id] == nil
                }
                precondition(next.job(id)!.downloadedBytes > initial && next.job(id)?.relay?.uploadFailure != nil && uploader.failedAttempts > 0)
                precondition(next.job(id)?.relay?.volume == nil && next.job(id)?.relay?.storage != nil)
                let payload = next.job(id)!.relay!.payload!
                for file in next.job(id)!.files where next.job(id)!.selected.contains(file.index) {
                    let size = try FileManager.default.attributesOfItem(atPath: payload.appendingPathComponent(file.path).path)[.size] as! NSNumber
                    precondition(size.uint64Value == file.length, "Pending disk payload was lost before cloud confirmation")
                }
                print("PASS PikPak offline: real peers finished all generated files in storage, including across app restarts; no upload or premature cleanup")
                uploader.offline = false
            }
            var selections = Set<[Int]>()
            try await until("verified RAM payload reaches upload sink",seconds:100) {
                if let selection = next.job(id)?.relay?.selection, !selection.isEmpty { selections.insert(selection) }
                if let current = next.gids[id] { precondition(current == gid, "Refilling must retain the same GID") }
                return [.completed,.failed,.paused].contains(next.job(id)?.phase ?? .metadata)
            }
            guard next.job(id)?.phase == .completed else {await next.stop(id);throw LocalTorrentError.message(next.job(id)?.message ?? "RAM relay did not complete")}
            precondition(Set(uploader.hashes.keys) == (rolling ? [1,2,3] : [1,3]))
            if rolling && !storageMode { precondition(selections.count > 1 && selections.allSatisfy { $0.count < 3 }, "The fixture must slide through a buffer smaller than its total") }
            if storageMode { precondition(selections == [[1, 2, 3]], "Storage with room for the whole fixture must not reopen its window for individual uploads") }
            // The larger storage window admits all generated files together;
            // they can finish in the same census. RAM mode still must drain
            // part of its bounded window while more pieces are arriving.
            if !storageMode {
                precondition(uploader.batchesSent.contains { $0 < (rolling ? 3 : 2) },
                             "every upload carried the whole batch; no file was saved while it was still downloading")
            }
            precondition(next.job(id)?.relay?.volume == nil)
            if let storage = next.job(id)?.relay?.storage {
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: storage.payload.path)
                precondition(leftovers.isEmpty, "Uploaded disk payload must be removed")
            }
            let entries = FileManager.default.enumerator(at: state, includingPropertiesForKeys: nil)!
            while let path = entries.nextObject() as? URL {
                precondition(!path.pathComponents.contains("FixtureFiles"), "Relay payload escaped into the disk-backed queue")
            }
            next.shutdown()
            print(storageMode ? "PASS real peers → RAM → storage → upload sink: selective SHA-256 verified files, restart/resume and automatic disk cleanup after commit" : "PASS real peers → RAM → upload sink: selective SHA-256 verified files, partial-piece pause/restart/resume, RAM identity retained and released after commit")
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
        precondition(relay.storage == nil, "legacy queues must keep their RAM-only behavior")
        precondition(relay.bufferAvailable == nil && relay.admissionBudget == relay.memoryBytes)

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
    @MainActor static func relayDestinationChecks() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("RAM/payload")
        let outside = root.appendingPathComponent("Disk")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: payload.appendingPathComponent("escape"), withDestinationURL: outside)
        let fixture = TorrentFixtureEngine(), engine: LocalTorrentDriving = fixture
        try await engine.start()
        let gid = try await engine.addTorrent(Data("synthetic".utf8), directory: payload, selection: [1])
        let valid = fixture.states[gid]!
        for wrong in [outside.appendingPathComponent("file.bin").path,
                      payload.path + "-other/file.bin", payload.path + "/../file.bin",
                      payload.path + "/escape/file.bin"] {
            fixture.states[gid] = valid
            var files = valid["files"] as! [[String: String]]
            // Even an unselected file may hold shared boundary pieces.
            files[1]["path"] = wrong
            fixture.states[gid]?["files"] = files
            fixture.states[gid]?["status"] = "active"
            do { try await engine.beginRelay(gid, directory: payload, selection: [1]); preconditionFailure("Relay accepted a file outside RAM") }
            catch { precondition(error as? LocalTorrentError == .ramDestinationMismatch) }
            precondition(fixture.begun.isEmpty && fixture.states[gid]?["status"] as? String == "paused")
        }
        fixture.states[gid] = valid; fixture.states[gid]?["files"] = [] as [[String: String]]
        do { try await engine.beginRelay(gid, directory: payload, selection: [1]); preconditionFailure("Relay accepted missing destination evidence") }
        catch { precondition(error as? LocalTorrentError == .ramDestinationMismatch) }
        fixture.states[gid] = valid
        try await engine.beginRelay(gid, directory: payload, selection: [1])
        precondition(fixture.begun.count == 1)
        try await engine.remove(gid)
        let (model, id) = try await prepared(root: root, engine: fixture)
        defer { model.shutdown() }
        model.ram = RelayFixtureRAM()
        let context = relayContext(), cloud = RelayFixtureCloud()
        model.relayContextProvider = { context }; model.relayUploaderFactory = { RelayFixtureUpload(cloud) }
        fixture.badManifest = true
        await model.downloadToPikPak(id, selected: [1], context: context, accountName: "Fixture account",
            parentID: "fixture", parentName: "Fixture", memoryBytes: 256 * 1024 * 1024)
        try await until("destination rejection is visible") { model.job(id)?.phase == .failed && !model.busy.contains(id) }
        precondition(model.job(id)?.message.contains(LocalTorrentError.ramDestinationMismatch.localizedDescription) == true)
        precondition(fixture.begun.count == 1, "A rejected relay must never be unpaused")
        await model.stop(id)
        print("PASS RAM destinations: disk paths, sibling prefixes, traversal, symlinks and missing paths refuse to resume")
    }

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
        try await until("space pressure flushes file 1") { cloud.uploads == [1] && model.relayTasks[id] == nil }

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
    @MainActor static func relayVerificationStability() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud(), mib: UInt64 = 1024 * 1024
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud)
        defer { model.shutdown() }
        model.relayFileCensusInterval = 0
        let gid = model.gids[id]!, volume = model.job(id)!.relay!.volume!
        let saved = volume.payload.appendingPathComponent("Examples/one")
        try LocalTorrentStore.protect(saved.deletingLastPathComponent())
        try Data("synthetic committed bytes".utf8).write(to: saved)
        cloud.receipts = [1]
        model.edit(id) { $0.relay?.uploaded = [1]; $0.completed = 100 * mib; $0.stalledSince = Date().addingTimeInterval(-600) }
        engine.setFileProgress(gid, [1: 100 * mib, 2: 4096])
        ram.availableOverride = volume.bytes / 4
        let starts = engine.begun.count, requests = cloud.requests.count

        // Zero is already an active hash check. A queued check is protected too.
        for key in ["verifiedLength", "verifyIntegrityPending"] {
            engine.states[gid]?[key] = key == "verifiedLength" ? "0" : "true"
            for _ in 0..<3 { await model.refreshRelay(id) }
            let job = model.job(id)!
            // A running check reports how far it has read, zero included; a check
            // still queued for a slot has no figure and keeps the plain wording.
            let running = key == "verifiedLength"
            let label = running ? "Checking downloaded pieces — 0%" : "Checking downloaded pieces"
            let note = running ? "Checking downloaded pieces before continuing — 0%"
                               : "Checking downloaded pieces before continuing…"
            precondition(job.checkingPieces == true && job.status == label, job.status)
            precondition(job.message == note && job.stalledSince == nil, job.message)
            precondition(job.relay?.selection == [1, 2] && engine.reselected.isEmpty && engine.begun.count == starts)
            precondition(FileManager.default.fileExists(atPath: saved.path) && cloud.requests.count == requests,
                         "Verification must not be interrupted by cleanup, admission or new uploads")
            engine.states[gid]?[key] = nil
        }
        // Verification can begin between the lightweight poll and file census.
        engine.checkingOnFileCensus = true
        await model.refreshRelay(id)
        precondition(engine.reselected.isEmpty && FileManager.default.fileExists(atPath: saved.path))
        engine.checkingOnFileCensus = false
        ram.availableOverride = nil
        await model.refreshRelay(id)
        precondition(model.job(id)?.checkingPieces == false && model.job(id)?.relay?.selection == [2, 3])
        precondition(engine.reselected.count == 1 && !FileManager.default.fileExists(atPath: saved.path),
                     "Once hashing finishes, the sliding window must reclaim space and keep progressing")
        var local = LocalTorrentJob(id: UUID(), name: "Synthetic verification", phase: .downloading)
        local.updateTransferStats(.init(["status":"active", "verifiedLength":"0", "downloadSpeed":"123"]))
        // No totalLength here, so there is no denominator and no figure to show:
        // the check is still named, just without a percentage.
        precondition(local.checkingPieces == true && local.downloadSpeed == 0
                     && local.status == "Checking downloaded pieces", local.status)
        local.updateTransferStats(.init(["status":"active", "verifyIntegrityPending":"false", "downloadSpeed":"123"]))
        precondition(local.checkingPieces == false && local.status == "Downloading")
        print("PASS verification: queued, zero-byte and racing hash checks keep their window intact; completion resumes admission and truthful status")
    }

    @MainActor static func stableRelayWindow() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud(), mib: UInt64 = 1024 * 1024
        let files = (1...20).map { ("Stable/file\($0)", 16 * mib) }
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        model.relayFlushWait = 0
        let gid = model.gids[id]!, initial = model.job(id)?.relay?.selection
        precondition(initial == Array(1...13))
        engine.setFileProgress(gid, [1: 16 * mib, 2: 4096])
        model.relayFileCensusAt[id] = nil; await model.refreshRelay(id)
        try await until("small file uploaded without reconnecting") { cloud.receipts == [1] && model.relayTasks[id] == nil }
        for _ in 0..<3 { model.relayFileCensusAt[id] = nil; await model.refreshRelay(id) }
        precondition(model.job(id)?.relay?.selection == initial && engine.reselected.isEmpty && engine.begun.count == 1,
                     "A small completed upload must leave a productive window connected")

        engine.setFileProgress(gid, [2: 16 * mib, 3: 4096])
        model.relayFileCensusAt[id] = nil; await model.refreshRelay(id)
        try await until("second file uploaded") { cloud.receipts == [1, 2] && model.relayTasks[id] == nil }
        model.relayFileCensusAt[id] = nil; await model.refreshRelay(id)
        precondition(model.job(id)?.relay?.selection == Array(3...15), "Reclaimed capacity must admit more files while older files remain incomplete")
        precondition(engine.reselected.count == 1 && engine.begun.count == 2)
        print("PASS connection stability: uploads continue without small window resets; useful reclaimed space admits files before the window finishes")
    }

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
        // Pressure requires reclaiming now; otherwise the final window stays
        // connected until its remaining files finish.
        ram.availableOverride = volume.bytes / 4
        engine.setFileProgress(gid, [1: 700, 2: 700, 3: 0])
        model.relayFileCensusAt[id] = nil
        await model.refreshRelay(id)
        try await until("file 1 unlinked", seconds: 10) { !exists("one.bin") }
        precondition(model.job(id)?.relay?.drained?.contains(1) == true)
        precondition(engine.reselected.last?.1 == [2, 3], "the drained file must be deselected before it is unlinked")
        precondition(exists("two.bin"), "a file that has not been uploaded must never be unlinked")

        // aria2 recreates an unselected file when its boundary piece is still
        // shared with the current selection. Reclaiming that stub on every
        // census pauses/reopens an unchanged window and drops all peers.
        try Data(repeating: 7, count: 700).write(to: payload.appendingPathComponent("one.bin"))
        let selections = engine.reselected.count, starts = engine.begun.count
        for _ in 0..<3 {
            model.relayFileCensusAt[id] = nil
            await model.refreshRelay(id)
        }
        precondition(engine.reselected.count == selections && engine.begun.count == starts,
                     "Recreated boundary stubs must not disconnect an unchanged download window")
        precondition(exists("one.bin"), "A harmless shared boundary stub may stay until the next window change")
        model.shutdown()
        print("PASS RAM reclaim: shared-piece safety, deselect before unlink, and no reconnect loop for recreated stubs")
    }
}

extension LocalTorrentTests {
    /// The third file enters as soon as the first is saved, even while file 2
    /// remains incomplete. No fixed batch boundary or volume reset is needed.
    @MainActor static func ramBoundaryClears() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let files = (1...7).map { ("Sliding/file\($0)", UInt64(100 * 1024 * 1024)) }
        let (model, engine, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud, files: files)
        defer { model.shutdown() }
        let gid = model.gids[id]!, uuid = model.job(id)?.relay?.volume?.uuid
        precondition(model.job(id)?.relay?.selection == [1, 2])
        model.relayFlushWait = 0
        for index in 1...files.count {
            engine.setFileProgress(gid, [index: files[index - 1].1, index + 1: 4096])
            model.relayFileCensusAt[id] = nil
            await model.refreshRelay(id)
            try await until("sliding file saved") { cloud.receipts.contains(index) && model.relayTasks[id] == nil }
            if index < files.count {
                model.relayFileCensusAt[id] = nil
                await model.refreshRelay(id)
                precondition(model.gids[id] == gid, "A refill must preserve the torrent GID")
                precondition(ram.released == 0 && ram.clears == 0, "A sliding window must never clear or detach RAM")
                precondition(model.job(id)?.relay?.volume?.uuid == uuid)
                let expected = index == files.count - 1 ? [index, index + 1] : Array((index + 1)...min(index + 2, files.count))
                precondition(model.job(id)?.relay?.selection == expected)
            }
        }
        precondition(model.job(id)?.phase == .completed && cloud.uploads == Array(1...files.count))
        precondition(Set(engine.begun.map { $0.0 }) == [gid] && !engine.reselected.isEmpty)
        precondition(ram.released == 1 && ram.volumes.isEmpty)
        print("PASS sliding window: seven files cross a two-file buffer with one GID, no clears, and incremental admission")
    }

}

extension LocalTorrentTests {
    @MainActor static func relayLiveLoginSwitch() async throws {
        for storageMode in [false, true] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
            let (model, engine, id, token) = try await startRelay(root: root, ram: ram, cloud: cloud,
                files: [("Examples/one", 32768), ("Examples/two", 32768), ("Examples/three", 32768)])
            defer { model.shutdown() }
            if storageMode {
                await model.switchRelayToStorage(id, parent: root)
                try await until("storage ready for login switch") { model.job(id)?.phase == .downloading && model.relayTasks[id] == nil }
            }
            model.relayFileCensusInterval = 0; model.relayFlushWait = 0
            var uploaders: [RelayFixtureUpload] = []
            model.relayUploaderFactory = {
                let uploader = RelayFixtureUpload(cloud); uploaders.append(uploader); return uploader
            }
            let gid = model.gids[id]!, payload = model.job(id)!.relay!.payload
            let selection = model.job(id)!.relay!.selection
            cloud.blockUploads = true
            engine.setFileProgress(gid, [1: 32768, 2: 8192])
            engine.states[gid]?["downloadSpeed"] = "8192"
            engine.states[gid]?["connections"] = "2"
            engine.connectedPeers = 2
            await model.refresh()
            try await until("token upload in flight") { model.job(id)?.relay?.stage == "hashing" && model.relayUploaders[id] != nil }
            let starts = engine.begun.count, pauses = engine.pauses.count, reselected = engine.reselected.count
            let downloaded = model.job(id)!.downloadedBytes
            let normal = relayContext(account: token.accountID, kind: .desktopOAuth)
            model.relayContextProvider = { normal }
            if storageMode { engine.states[gid]?["verifiedLength"] = "0" }
            await model.refresh()
            try await until("only old upload helper stopped") { uploaders[0].stopped && model.relayTasks[id] == nil }
            if storageMode {
                precondition(model.job(id)?.checkingPieces == true)
                precondition(model.job(id)?.relay?.selection == selection)
                engine.states[gid]?["verifiedLength"] = nil
            }
            await model.refresh()
            try await until("normal login takes over uploads") {
                model.job(id)?.relay?.credentialKind == .desktopOAuth && model.job(id)?.relay?.stage == "hashing"
                    && cloud.credentialKinds.last == .desktopOAuth && model.relayUploaders[id] != nil
            }
            precondition(cloud.uploads.isEmpty && cloud.requests.allSatisfy { $0["account_id"] as? String == token.accountID })
            precondition(model.gids[id] == gid && model.job(id)?.relay?.payload == payload && model.job(id)?.relay?.selection == selection)
            precondition(engine.begun.count == starts && engine.pauses.count == pauses && engine.reselected.count == reselected,
                         "Changing the upload login must never pause, reopen or reselect the torrent")
            engine.setFileProgress(gid, [1: 32768, 2: 16384])
            await model.refresh()
            precondition(model.job(id)!.downloadedBytes > downloaded && model.job(id)?.downloadSpeed == 8192 && model.job(id)?.peers == 2)
            cloud.blockUploads = false
            try await until("file uploaded using normal login") { cloud.uploads == [1] && model.relayTasks[id] == nil }
            precondition(model.job(id)?.relay?.uploadFailure == nil && model.job(id)?.phase == .downloading)
            // An idle worker needs no restart: the card follows the selected
            // saved login even when no complete file is ready to upload yet.
            model.relayContextProvider = { token }
            await model.refresh()
            precondition(model.job(id)?.relay?.credentialKind == .personalAccessToken)
            precondition(engine.begun.count == starts && engine.pauses.count == pauses && engine.reselected.count == reselected)
            await model.pause(id)
            model.relayContextProvider = { normal }
            await model.refresh()
            precondition(model.job(id)?.phase == .paused, "Selecting a login cannot resume a manually paused torrent")
        }
        print("PASS live login switch: token → normal changes only upload helpers, preserves peers, GID, buffer, verification and manual Pause")
    }

    /// A transfer is bound to a PikPak account, not to one of this Mac's saved
    /// login entries. Account-entry UUIDs are re-issued when a session is
    /// re-registered, and a transfer running for days must survive that; the
    /// login method is also the user's to change mid-transfer, which is how an
    /// upload moves off a token's 25% allowance onto the full account.
    @MainActor static func relayLoginSwitch() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), cloud = RelayFixtureCloud()
        let (model, _, id, _) = try await startRelay(root: root, ram: ram, cloud: cloud)
        precondition(model.job(id)?.relay?.credentialKind == .personalAccessToken)

        await model.pause(id)
        // Same PikPak account, different saved entry and different login kind.
        let switched = relayContext(identity: UUID(), account: "account-a", kind: .desktopOAuth)
        model.relayContextProvider = { switched }
        await model.resumeRelay(id)
        try await until("resumes under the new login") { model.job(id)?.phase == .downloading && !model.busy.contains(id) }
        precondition(model.job(id)?.relay?.credentialKind == .desktopOAuth, "the stored login must follow the active one")
        precondition(model.job(id)?.relay?.identity == switched.identity, "the stored entry must follow the active one")
        precondition(model.job(id)?.relay?.accountID == "account-a", "the PikPak account itself must never change")

        // A different PikPak account cannot upload this transfer, but local
        // downloading no longer depends on which cloud account is selected.
        await model.pause(id)
        let invocations = cloud.invocations
        model.relayContextProvider = { relayContext(identity: UUID(), account: "account-b", kind: .desktopOAuth) }
        await model.resumeRelay(id)
        try await until("download continues while another account is selected") { model.job(id)?.phase == .downloading && model.relayTasks[id] == nil }
        precondition(model.job(id)?.relay?.uploadFailure?.awaitingAccount == true && cloud.invocations == invocations)
        model.shutdown()
        print("PASS relay login switch: new login continues; another cloud account holds only uploads")
    }
}

private struct TorrentProgressFixtureView: View {
    @State private var empty = false
    @State private var paused = false
    private var job: LocalTorrentJob {
        var value = LocalTorrentJob(id: UUID(), name: "Generated torrent", phase: paused ? .paused : .downloading)
        value.selected = [1, 2, 3, 4]
        value.total = 4 * 1024 * 1024 * 1024; value.completed = 1024 * 1024 * 1024
        value.downloadSpeed = empty || paused ? 0 : 8 * 1024 * 1024; value.uploadSpeed = 128 * 1024
        value.peers = empty || paused ? 0 : 1
        value.relay = TorrentRelayState(identity: UUID(), accountID: "synthetic", credentialKind: .desktopOAuth,
            accountName: "Synthetic account", parentID: "", parentName: "Generated fixtures", rootName: "Example transfer",
            memoryBytes: 2 * 1024 * 1024 * 1024, batches: [])
        value.relay?.selection = [2, 3]; value.relay?.uploaded = [1]
        value.relay?.downloadedBytes = 2 * 1024 * 1024 * 1024; value.relay?.bufferUsed = 1024 * 1024 * 1024
        let owner = value.id
        value.relay?.volume = TorrentRAMVolume(device: "fixture", image: "ram://fixture", volumeDevice: "fixture",
            uuid: "synthetic", mount: "/tmp/synthetic-unused", owner: owner, bytes: 2 * 1024 * 1024 * 1024)
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Generated torrent · UI fixture").font(.title2)
            TorrentRelayProgress(job: job, relay: job.relay!, peers: empty || paused ? [] : [
                LocalTorrentPeer(address: "127.0.0.1:6881", downloadSpeed: 8 * 1024 * 1024, uploadSpeed: 128 * 1024, seeder: true)
            ], torrentRunning: !paused)
            Divider()
            HStack {
                Button(empty ? "Restore synthetic peer" : "Set peer count to zero") { empty.toggle() }
                Button(paused ? "Resume fixture" : "Pause fixture") { paused.toggle() }
            }
            Spacer()
            Text("Generated fixture only. No downloads or accounts are read.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}
