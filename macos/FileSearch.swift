import Combine
import Darwin
import Foundation

enum FileSearchScope {
    case expanded
    case root

    var title: String { self == .expanded ? "Current expanded items" : "Search from PikPak root" }
    var shortcut: String { self == .expanded ? "⌘F" : "⌘⇧F" }
}

struct FileSearchAncestor: Codable, Hashable {
    let id: String
    let name: String
}

struct FileSearchItem: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let size: UInt64
    let mimeType: String?
    let modifiedTime: String?
    var isFolder: Bool { kind == "drive#folder" }
}

struct FileSearchMatch: Identifiable, Equatable {
    let item: FileSearchItem
    let ancestors: [FileSearchAncestor]
    let score: Int
    let linkID: UUID?
    let sourceName: String

    init(item: FileSearchItem, ancestors: [FileSearchAncestor], score: Int,
         linkID: UUID? = nil, sourceName: String = "PikPak") {
        self.item = item
        self.ancestors = ancestors
        self.score = score
        self.linkID = linkID
        self.sourceName = sourceName
    }

    // The same file can occur in several shared links. Its result identity
    // must keep the owning link, even when PikPak reuses the file id.
    var id: String { linkID.map { "\($0.uuidString):\(item.id)" } ?? item.id }
    var parentPath: String { ([sourceName] + ancestors.map(\.name)).joined(separator: " › ") }
    var fullPath: String { parentPath + " › " + item.name }
}

struct FileSearchProgress: Codable, Equatable {
    var indexedItems = 0
    var scannedFolders = 0
    var discoveredFolders = 0
    var failedFolders = 0
}

struct FileSearchEvent: Decodable {
    let event: String
    let parentId: String?
    let ancestors: [FileSearchAncestor]?
    let items: [FileSearchItem]?
    let nextPageToken: String?
    let progress: FileSearchProgress
    let code: String?
    let message: String?
}

struct FileSearchNavigation {
    let match: FileSearchMatch
    let ancestors: [FileSearchAncestor]
    let items: [FileSearchItem]
    let hasLoadedDirectory: Bool
    let nextPageToken: String?
    let directories: [FileSearchDirectory]
    let scope: FileSearchScope
}

/// Only listings on the result's ancestry are handed to the Browser. A root
/// search can reveal a deep result without replacing the rest of the tree or
/// fetching each ancestor again on the foreground request channel.
struct FileSearchDirectory {
    let parentID: String
    let ancestors: [FileSearchAncestor]
    let items: [FileSearchItem]
    let isLoaded: Bool
    let nextPageToken: String?
}

/// Pure metadata index, confined to the worker queue. Names are normalized
/// once per entry rather than on the main thread for every keystroke.
final class FileSearchIndex {
    private struct Entry {
        let item: FileSearchItem
        let ancestors: [FileSearchAncestor]
        let normalizedName: String
        let linkID: UUID?
        let sourceName: String
    }
    private var entries: [String: Entry] = [:]
    private var seenThisScan = Set<String>()
    private var loadedDirectories = Set<String>()
    private var nextPageTokens: [String: String] = [:]
    private(set) var progress = FileSearchProgress()
    private(set) var failures: [String] = []
    private(set) var complete = false
    var count: Int { entries.count }

    func replaceExpandedItems(_ matches: [FileSearchMatch]) {
        entries = [:]
        for match in matches {
            entries[match.id] = Entry(item: match.item, ancestors: match.ancestors,
                                     normalizedName: Self.normalized(match.item.name),
                                     linkID: match.linkID, sourceName: match.sourceName)
        }
        progress = FileSearchProgress(indexedItems: entries.count)
        failures = []
        complete = true
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    func beginScan() {
        seenThisScan.removeAll(keepingCapacity: true)
        loadedDirectories.removeAll(keepingCapacity: true)
        nextPageTokens.removeAll(keepingCapacity: true)
        progress = FileSearchProgress()
        failures = []
        complete = false
    }

    func ingest(_ event: FileSearchEvent) {
        progress = event.progress
        switch event.event {
        case "page":
            guard let parentID = event.parentId, let ancestors = event.ancestors,
                  let items = event.items else { return }
            loadedDirectories.insert(parentID)
            nextPageTokens[parentID] = event.nextPageToken
            for item in items where !item.id.isEmpty {
                entries[item.id] = Entry(item: item, ancestors: ancestors,
                                        normalizedName: Self.normalized(item.name),
                                        linkID: nil, sourceName: "PikPak")
                seenThisScan.insert(item.id)
            }
        case "failure":
            let path = (["PikPak"] + (event.ancestors ?? []).map(\.name)).joined(separator: " › ")
            addFailure("Source: PikPak name search\nCode: \(event.code ?? "SEARCH_FAILED")\nMessage: \(event.message ?? "This folder could not be scanned.")\nFolder: \(path)")
        case "finished":
            complete = progress.failedFolders == 0
            if complete {
                entries = entries.filter { seenThisScan.contains($0.key) }
            }
        default: break
        }
    }

    func addFailure(_ text: String) {
        if failures.count < 20 { failures.append(Self.redacted(text)) }
    }

    /// The engine prints `note:` status lines — a refresh token it already
    /// rotated and persisted, for instance — to stderr after every command,
    /// successful or not. They are not problems, and because they arrive last
    /// they otherwise replace the real cause in a one-line diagnostic. Drop
    /// them, with the indented continuations that can carry a raw token, before
    /// any stderr text becomes a user-facing error.
    static func withoutStatusNotes(_ text: String) -> String {
        var kept: [String] = []
        var droppingContinuation = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if droppingContinuation, line.first?.isWhitespace == true, !trimmed.isEmpty { continue }
            droppingContinuation = false
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("note:") { droppingContinuation = true; continue }
            // A rotated-token warning is kept, but its continuation is the token.
            if lowered.hasPrefix("warning:"), lowered.contains("refresh token rotated") {
                droppingContinuation = true
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func redacted(_ text: String) -> String {
        var result = String(text.prefix(8000))
        for pattern in [
            "(?i)(?:refresh_token|access_token|client_secret|authorization)[\\\"\\s:=]+[^\\s,}\\\"]+",
            "(?i)bearer\\s+[^\\s\\\"]+",
            "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }

    func search(_ query: String, limit: Int) -> (matches: [FileSearchMatch], total: Int) {
        let normalized = Self.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ([], 0) }
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [FileSearchMatch] = []
        for entry in entries.values {
            guard let score = Self.score(name: entry.normalizedName, query: normalized, tokens: tokens) else { continue }
            matches.append(FileSearchMatch(item: entry.item, ancestors: entry.ancestors, score: score,
                                           linkID: entry.linkID, sourceName: entry.sourceName))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let order = $0.item.name.localizedStandardCompare($1.item.name)
            if order != .orderedSame { return order == .orderedAscending }
            // Deterministic tie breaker prevents identical names jumping rows.
            return $0.id < $1.id
        }
        return (Array(matches.prefix(max(limit, 1))), matches.count)
    }

    private static func score(name: String, query: String, tokens: [String]) -> Int? {
        if name == query { return 0 }
        if name.hasPrefix(query) { return 10 }
        if name.contains(query) { return 20 }
        if tokens.count > 1, tokens.allSatisfy({ name.contains($0) }) { return 30 }
        // VS Code-style abbreviated typing, with exact/prefix/substring hits
        // first. Multi-word queries use AND matching instead of loose fuzziness.
        guard tokens.count == 1, query.count >= 3 else { return nil }
        var cursor = name.startIndex
        var gaps = 0
        for character in query {
            guard let found = name[cursor...].firstIndex(of: character) else { return nil }
            gaps += name.distance(from: cursor, to: found)
            cursor = name.index(after: found)
        }
        return 100 + gaps
    }

    func navigation(for match: FileSearchMatch, scope: FileSearchScope = .root) -> FileSearchNavigation {
        // Reveal a folder's own row, just like a file. Do not enter the folder
        // and leave its children selected while its own row disappears.
        let ancestors = match.ancestors
        let parentID = ancestors.last?.id ?? ""
        let routeIDs = [""] + ancestors.map(\.id)
        let routeSet = Set(routeIDs)
        var itemsByParent: [String: [FileSearchItem]] = [:]
        for entry in entries.values where entry.linkID == match.linkID {
            let id = entry.ancestors.last?.id ?? ""
            if routeSet.contains(id) { itemsByParent[id, default: []].append(entry.item) }
        }
        let directories = scope == .expanded ? [] : routeIDs.enumerated().map { offset, id in
            FileSearchDirectory(parentID: id, ancestors: Array(ancestors.prefix(offset)),
                                items: itemsByParent[id] ?? [], isLoaded: loadedDirectories.contains(id),
                                nextPageToken: nextPageTokens[id])
        }
        let siblings = itemsByParent[parentID] ?? []
        return FileSearchNavigation(match: match, ancestors: ancestors, items: siblings,
                                    hasLoadedDirectory: loadedDirectories.contains(parentID),
                                    nextPageToken: nextPageTokens[parentID],
                                    directories: directories, scope: scope)
    }
}

struct FileSearchConfiguration {
    let executable: URL
    let directory: URL
    let environment: [String: String]
}

/// A separate read-only helper, never the downloader/uploader or foreground
/// browser process. Closing the palette terminates only this process.
final class FileSearchJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var runningProcessIdentifier: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func start(configuration: FileSearchConfiguration,
               onEvent: @escaping (FileSearchEvent) -> Void,
               onFinish: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let child = Process()
            let stdout = Pipe(), stderr = Pipe()
            child.executableURL = configuration.executable
            child.arguments = ["search-index", "--workers", "4"]
            child.currentDirectoryURL = configuration.directory
            child.environment = configuration.environment
            child.qualityOfService = .utility
            child.standardOutput = stdout
            child.standardError = stderr
            child.standardInput = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); onFinish(0, ""); return }
            process = child
            do { try child.run() }
            catch { lock.unlock(); onFinish(-1, error.localizedDescription); return }
            lock.unlock()

            let errorBuffer = FileSearchErrorBuffer()
            let errorDone = DispatchGroup()
            errorDone.enter()
            DispatchQueue.global(qos: .utility).async {
                Self.readChunks(stderr.fileHandleForReading) { errorBuffer.append($0) }
                errorDone.leave()
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var buffer = Data()
            Self.readChunks(stdout.fileHandleForReading) { chunk in
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    if let event = try? decoder.decode(FileSearchEvent.self, from: line) {
                        onEvent(event)
                    }
                }
                // A corrupt helper must not grow an unbounded line buffer.
                if buffer.count > 4 * 1024 * 1024 {
                    errorBuffer.append(Data("Search helper returned an oversized response.\n".utf8))
                    cancel()
                    buffer.removeAll()
                }
            }
            if !buffer.isEmpty, let event = try? decoder.decode(FileSearchEvent.self, from: buffer) {
                onEvent(event)
            }
            child.waitUntilExit()
            errorDone.wait()
            lock.lock(); process = nil; lock.unlock()
            onFinish(child.terminationStatus, errorBuffer.text)
        }
    }

    private static func readChunks(_ handle: FileHandle, consume: (Data) -> Void) {
        defer { try? handle.close() }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            consume(Data(bytes.prefix(count)))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        // Only kill our own still-running Process object, never a reused PID.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

private final class FileSearchErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data.prefix(max(0, 8000 - bytes.count)))
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return FileSearchIndex.redacted(String(decoding: bytes, as: UTF8.self))
    }
}

private struct FileSearchSnapshot {
    let query: String
    let matches: [FileSearchMatch]
    let total: Int
    let indexed: Int
    let progress: FileSearchProgress
    let failures: [String]
    let complete: Bool
}

/// All index mutation, decoding delivery, and matching is serialized here.
/// Generation checks protect both the index and UI against late cancelled
/// process output (including output arriving after sign-out/account changes).
private final class FileSearchWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wky.pikpak.name-search", qos: .utility)
    private var rootIndex = FileSearchIndex()
    private var expandedIndex = FileSearchIndex()
    private var scope = FileSearchScope.root
    private var index: FileSearchIndex { scope == .root ? rootIndex : expandedIndex }
    private var generation = UUID()
    private var query = ""
    private var limit = 100
    private var publicationScheduled = false
    private let publish: (UUID, FileSearchSnapshot) -> Void

    init(publish: @escaping (UUID, FileSearchSnapshot) -> Void) { self.publish = publish }

    func rebind(_ id: UUID, scope: FileSearchScope? = nil, reset: Bool = false,
                begin: Bool = false, expandedItems: [FileSearchMatch]? = nil) {
        queue.async { [self] in
            generation = id
            if let scope { self.scope = scope }
            if reset { rootIndex = FileSearchIndex(); expandedIndex = FileSearchIndex(); query = "" }
            if let expandedItems { expandedIndex.replaceExpandedItems(expandedItems) }
            if begin { index.beginScan() }
        }
    }

    func receive(_ event: FileSearchEvent, runID: UUID) {
        queue.async { [self] in
            guard generation == runID else { return }
            index.ingest(event)
            scheduleSnapshot()
        }
    }

    func finish(_ code: Int32, error: String, runID: UUID,
                completion: @escaping (FileSearchSnapshot) -> Void) {
        queue.async { [self] in
            guard generation == runID else { return }
            if code != 0 || (!index.complete && index.failures.isEmpty) {
                let reported = FileSearchIndex.withoutStatusNotes(error)
                index.addFailure("Source: PikPak name search\nCode: SEARCH_ENGINE_\(code)\nMessage: \(reported.isEmpty ? "The scan stopped before completion. Scan again to retry." : reported)")
            }
            completion(makeSnapshot())
        }
    }

    func search(_ query: String, limit: Int, runID: UUID) {
        queue.async { [self] in
            guard generation == runID else { return }
            self.query = query
            self.limit = limit
            scheduleSnapshot()
        }
    }

    func navigation(_ match: FileSearchMatch, runID: UUID,
                    completion: @escaping (FileSearchNavigation) -> Void) {
        queue.async { [self] in
            guard generation == runID else { return }
            completion(index.navigation(for: match, scope: scope))
        }
    }

    private func scheduleSnapshot() {
        guard !publicationScheduled else { return }
        publicationScheduled = true
        queue.asyncAfter(deadline: .now() + 0.18) { [self] in
            publicationScheduled = false
            publish(generation, makeSnapshot())
        }
    }

    private func makeSnapshot() -> FileSearchSnapshot {
        let found = index.search(query, limit: limit)
        return FileSearchSnapshot(query: query, matches: found.matches, total: found.total,
                                  indexed: index.count, progress: index.progress,
                                  failures: index.failures, complete: index.complete)
    }
}

@MainActor
final class FileSearchModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var scope = FileSearchScope.root
    @Published private(set) var contextName = "My PikPak"
    @Published private(set) var query = ""
    @Published private(set) var results: [FileSearchMatch] = []
    @Published private(set) var totalMatches = 0
    @Published private(set) var indexedItems = 0
    @Published private(set) var progress = FileSearchProgress()
    @Published private(set) var failures: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isComplete = false
    @Published private(set) var isResolving = false
    @Published var selectedID: String?
    @Published private(set) var focusRequest = UUID()
    private var configuration: FileSearchConfiguration?
    private var job: FileSearchJob?
    private var generation = UUID()
    private var resultLimit = 100
    private var queryTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var hasStartedScan = false
    private var rootCacheComplete = false
    private var configurationFailure: String?
    private lazy var worker = FileSearchWorker { [weak self] runID, snapshot in
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == runID, self.isPresented else { return }
            self.apply(snapshot)
        }
    }

    var canScan: Bool { scope == .root && configuration != nil && !isScanning && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var resourceProcessIdentifier: Int32? { job?.runningProcessIdentifier }

    func present(scope: FileSearchScope = .root, configuration: FileSearchConfiguration? = nil,
                 expandedItems: [FileSearchMatch] = [], contextName: String = "My PikPak",
                 failure: String? = nil) {
        if self.scope != scope || scope == .expanded {
            stopScan()
            results = []; totalMatches = 0; selectedID = nil; indexedItems = 0
            progress = FileSearchProgress()
            isComplete = scope == .expanded || rootCacheComplete
            hasStartedScan = isComplete
            resultLimit = 100
        }
        self.scope = scope
        self.contextName = contextName
        self.configuration = scope == .root ? configuration : nil
        configurationFailure = failure
        failures = failure.map { [$0] } ?? []
        isPresented = true
        focusRequest = UUID()
        if !isComplete && !isScanning { hasStartedScan = false }
        worker.rebind(generation, scope: scope, expandedItems: scope == .expanded ? expandedItems : nil)
        if scope == .root && !query.isEmpty && !isComplete && !isScanning { scanAgain() }
        requestMatches()
    }

    func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        results = []
        totalMatches = 0
        selectedID = nil
        resultLimit = 100
        queryTask?.cancel()
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []; totalMatches = 0
            requestMatches()
            return
        }
        queryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.hasStartedScan { self.scanAgain() }
            self.requestMatches()
        }
    }

    func scanAgain() { scanAgain(automatic: false) }
    private func scanAgain(automatic: Bool) {
        guard canScan, let configuration else { return }
        retryTask?.cancel(); retryTask = nil
        if !automatic { retryAttempt = 0 }
        job?.cancel()
        generation = UUID()
        let runID = generation
        isScanning = true
        hasStartedScan = true
        isComplete = false
        rootCacheComplete = false
        failures = []
        worker.rebind(runID, begin: true)
        requestMatches()
        let job = FileSearchJob()
        self.job = job
        let worker = worker
        job.start(configuration: configuration, onEvent: { event in
            worker.receive(event, runID: runID)
        }, onFinish: { [weak self] code, error in
            worker.finish(code, error: error, runID: runID) { snapshot in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == runID else { return }
                    self.isScanning = false
                    self.job = nil
                    self.apply(snapshot)
                    if code != 0 || !snapshot.complete { self.scheduleRetry(runID) }
                    else { self.retryAttempt = 0 }
                }
            }
        })
    }

    func stopScan() {
        retryTask?.cancel(); retryTask = nil; retryAttempt = 0
        queryTask?.cancel()
        job?.cancel()
        job = nil
        generation = UUID()
        worker.rebind(generation)
        isScanning = false
        isResolving = false
        // Keep partial metadata in memory for immediate subsequent queries.
    }

    private func scheduleRetry(_ runID: UUID) {
        guard isPresented, scope == .root, generation == runID else { return }
        let delay = AutomaticRecovery.delay(attempt: retryAttempt)
        retryAttempt = AutomaticRecovery.nextAttempt(retryAttempt)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.isPresented, self.generation == runID, !Task.isCancelled else { return }
            self.retryTask = nil
            self.scanAgain(automatic: true)
        }
    }

    func close() {
        stopScan()
        isPresented = false
        isResolving = false
    }

    func reset() {
        close()
        configuration = nil
        configurationFailure = nil
        query = ""; results = []; totalMatches = 0; indexedItems = 0
        progress = FileSearchProgress(); failures = []; isComplete = false
        hasStartedScan = false
        rootCacheComplete = false
        worker.rebind(generation, reset: true)
    }

    func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : results.count)
        selectedID = results[min(max(current + offset, 0), results.count - 1)].id
    }

    func showMore() {
        resultLimit += 100
        requestMatches()
    }

    func openSelection(_ match: FileSearchMatch? = nil, reveal: @escaping (FileSearchNavigation) -> Void) {
        guard !isResolving, let selected = match ?? results.first(where: { $0.id == selectedID }) ?? results.first else { return }
        isResolving = true
        let runID = generation
        worker.navigation(selected, runID: runID) { [weak self] navigation in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented, self.generation == runID else { return }
                self.close()
                reveal(navigation)
            }
        }
    }

    private func requestMatches() {
        worker.search(query, limit: resultLimit, runID: generation)
    }

    private func apply(_ snapshot: FileSearchSnapshot) {
        guard snapshot.query == query else { return }
        results = snapshot.matches
        totalMatches = snapshot.total
        indexedItems = snapshot.indexed
        progress = snapshot.progress
        failures = (configurationFailure.map { [$0] } ?? []) + snapshot.failures
        isComplete = snapshot.complete
        if scope == .root { rootCacheComplete = snapshot.complete }
        if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }
}
