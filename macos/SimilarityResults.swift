import AppKit
import Combine
import Foundation

final class SimilarityTreeNode: NSObject {
    let id: String
    let name: String
    let path: String
    let file: SimilarityFile?
    var children: [SimilarityTreeNode] = []
    var fileCount = 0
    init(id: String, name: String, path: String, file: SimilarityFile? = nil) {
        self.id = id; self.name = name; self.path = path; self.file = file
    }
}

struct SimilarityResultIndex {
    let roots: [SimilarityTreeNode]
    let files: [SimilarityFile]
    let byID: [String: SimilarityFile]
    let byScoreID: [String: SimilarityFile]
    let exactGroups: [String: [SimilarityFile]]
    let exactGroupForFile: [String: String]

    static func build(_ report: SimilarityReport) -> Self {
        var seen = Set<String>()
        let files = (report.files ?? report.groups.flatMap(\.members)).filter { seen.insert($0.id).inserted }
        let root = SimilarityTreeNode(id: "root", name: "Scanned Files", path: "")
        var folders = ["": root]
        for file in files {
            var parent = root, path = ""
            for component in file.path.split(separator: "/").dropLast() {
                path += "/" + component
                if let folder = folders[path] { parent = folder }
                else {
                    let folder = SimilarityTreeNode(id: "folder:" + path, name: String(component), path: path)
                    folders[path] = folder; parent.children.append(folder); parent = folder
                }
            }
            parent.children.append(SimilarityTreeNode(id: file.id, name: file.name, path: file.path, file: file))
        }
        func sort(_ node: SimilarityTreeNode) {
            node.children.sort {
                if ($0.file == nil) != ($1.file == nil) { return $0.file == nil }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            node.fileCount = node.file == nil ? 0 : 1
            for child in node.children { sort(child); node.fileCount += child.fileCount }
        }
        sort(root)
        var roots = root.children
        // Omit unhelpful single-child prefixes such as /Users/name/Documents.
        while roots.count == 1, roots[0].file == nil, roots[0].children.count == 1,
              roots[0].children[0].file == nil { roots = roots[0].children }
        var exactGroups: [String: [SimilarityFile]] = [:], membership: [String: String] = [:]
        for group in report.groups where group.isExact {
            exactGroups[group.id] = group.members
            for file in group.members { membership[file.id] = group.id }
        }
        return .init(roots: roots, files: files, byID: Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            byScoreID: Dictionary(files.map { ($0.scoreID, $0) }, uniquingKeysWith: { a, _ in a }),
            exactGroups: exactGroups, exactGroupForFile: membership)
    }

    func filteredRoots(_ query: String) -> [SimilarityTreeNode] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return roots }
        func filter(_ node: SimilarityTreeNode) -> SimilarityTreeNode? {
            if node.path.localizedStandardContains(query) { return node }
            guard node.file == nil else { return nil }
            let children = node.children.compactMap(filter)
            guard !children.isEmpty else { return nil }
            let copy = SimilarityTreeNode(id: node.id, name: node.name, path: node.path)
            copy.children = children; copy.fileCount = children.reduce(0) { $0 + $1.fileCount }
            return copy
        }
        return roots.compactMap(filter)
    }
}

struct SimilarityScoreRow: Decodable {
    struct Entry: Decodable { let fileId: String; let score: Double }
    let fileId: String
    let entries: [Entry]
    let unavailable: [String: UInt64]
    let omitted: UInt64
}

struct SimilarityRelatedFile: Identifiable {
    let file: SimilarityFile
    let score: Double?
    let identical: Bool
    var id: String { file.id }
    var scoreLabel: String { score.map { String(format: "%.1f%%", $0 * 100) } ?? "Identical" }
}

/// Result parsing and row queries are separate from scan progress and browser
/// observation. A changed selection cancels its helper and rejects late output.
@MainActor final class SimilarityResultsModel: ObservableObject {
    @Published private(set) var index: SimilarityResultIndex?
    @Published private(set) var roots: [SimilarityTreeNode] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var related: [SimilarityRelatedFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isIndexing = false
    @Published private(set) var error: String?
    @Published private(set) var unavailable: [String: UInt64] = [:]
    @Published private(set) var omitted: UInt64 = 0
    @Published var query = "" { didSet { filterTree() } }
    @Published var minimumScore = 0.9 { didSet { filterMatches() } }
    @Published var identicalOnly = false { didSet { filterMatches() } }
    private var report: SimilarityReport?
    private var configuration: SimilarityConfiguration?
    private var generation = UUID()
    private var requestID = UUID()
    private var indexTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var rows: [String: SimilarityScoreRow] = [:]
    private var rowOrder: [String] = []
    private var allRelated: [SimilarityRelatedFile] = []
    var selectedFile: SimilarityFile? { selectedID.flatMap { index?.byID[$0] } }

    func reset() {
        generation = UUID(); requestID = UUID()
        indexTask?.cancel(); queryTask?.cancel(); matchTask?.cancel(); searchTask?.cancel()
        indexTask = nil; queryTask = nil; searchTask = nil
        index = nil; roots = []; selectedID = nil; related = []; allRelated = []; rows = [:]; rowOrder = []
        isLoading = false; isIndexing = false; error = nil; unavailable = [:]; omitted = 0
        report = nil; configuration = nil; query = ""
    }
    func load(_ report: SimilarityReport, configuration: SimilarityConfiguration?) {
        reset(); self.report = report; self.configuration = configuration
        minimumScore = report.threshold; identicalOnly = false; isIndexing = true
        let token = generation
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { SimilarityResultIndex.build(report) }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.index = index; self.roots = index.roots; self.isIndexing = false
            // Let the user choose the reference file instead of fetching a
            // potentially large cloud original as a side effect of finishing.
        }
    }
    func select(_ id: String?) {
        guard selectedID != id else { return }
        queryTask?.cancel(); matchTask?.cancel(); requestID = UUID(); selectedID = id
        allRelated = []; related = []; unavailable = [:]; omitted = 0; error = nil; isLoading = false
        guard let file = selectedFile, let index else { return }
        let exact = index.exactGroupForFile[file.id].flatMap { index.exactGroups[$0] } ?? []
        allRelated = exact.filter { $0.id != file.id }.map { .init(file: $0, score: nil, identical: true) }; filterMatches()
        if let row = rows[file.scoreID] { apply(row, file: file); return }
        guard let configuration, let run = report?.runId, let revision = report?.resultRevision, let offset = file.engineIndex else { return }
        let token = requestID; isLoading = true
        queryTask = Task { [weak self] in
            do {
                let input: [String: Any] = ["data_dir": configuration.dataDirectory.path, "run_id": run,
                    "result_revision": revision, "file_id": file.scoreID, "row_offset": offset]
                let data = try JSONSerialization.data(withJSONObject: input)
                let output = try await SimilarityHelper.request(configuration: configuration, command: "similarity-scores", input: data)
                let row = try await Task.detached(priority: .userInitiated) {
                    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    return try decoder.decode(SimilarityScoreRow.self, from: output)
                }.value
                try Task.checkCancellation()
                guard let self, self.requestID == token else { return }
                guard row.fileId == file.scoreID else { throw CloudDriveError.message("The returned scores belong to a different file.") }
                self.rows[file.scoreID] = row; self.rowOrder.append(file.scoreID)
                while self.rowOrder.count > 4 { self.rows[self.rowOrder.removeFirst()] = nil }
                self.apply(row, file: file)
            } catch {
                guard let self, self.requestID == token, !Task.isCancelled else { return }
                self.isLoading = false; self.error = FileSearchIndex.redacted(error.localizedDescription)
            }
        }
    }
    func retry() { let id = selectedID; selectedID = nil; select(id) }
    private func apply(_ row: SimilarityScoreRow, file: SimilarityFile) {
        guard let index else { return }
        matchTask?.cancel(); isLoading = true
        let token = requestID
        matchTask = Task { [weak self] in
            let matches = await Task.detached(priority: .userInitiated) { Self.matches(row, file: file, index: index) }.value
            guard let self, !Task.isCancelled, self.requestID == token else { return }
            self.allRelated = matches; self.unavailable = row.unavailable; self.omitted = row.omitted
            self.filterMatches(); self.isLoading = false
        }
    }
    private nonisolated static func matches(_ row: SimilarityScoreRow, file: SimilarityFile, index: SimilarityResultIndex) -> [SimilarityRelatedFile] {
        let exact = index.exactGroupForFile[file.id].flatMap { index.exactGroups[$0] } ?? []
        let exactIDs = Set(exact.map(\.id))
        var seen = Set<String>()
        var matches: [SimilarityRelatedFile] = row.entries.compactMap { entry in
            guard entry.score.isFinite, (-1...1).contains(entry.score), let other = index.byScoreID[entry.fileId], other.id != file.id,
                  seen.insert(other.id).inserted else { return nil }
            return .init(file: other, score: entry.score, identical: exactIDs.contains(other.id))
        }
        matches += exact.filter { $0.id != file.id && seen.insert($0.id).inserted }.map { .init(file: $0, score: nil, identical: true) }
        matches.sort {
            if $0.identical != $1.identical { return $0.identical }
            if $0.score != $1.score { return ($0.score ?? 1) > ($1.score ?? 1) }
            return $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending
        }
        return matches
    }
    private func filterMatches() {
        related = allRelated.filter { identicalOnly ? $0.identical : $0.identical || ($0.score.map { $0 >= minimumScore } ?? false) }
    }
    private func filterTree() {
        searchTask?.cancel()
        guard let index else { return }
        let query = query, token = generation
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
            let roots = await Task.detached(priority: .userInitiated) { index.filteredRoots(query) }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.roots = roots
        }
    }
    #if FINDER_WORKSPACE_TESTS
    func setFixtureRow(_ row: SimilarityScoreRow) {
        rows[row.fileId] = row
        if let file = selectedFile, file.scoreID == row.fileId { apply(row, file: file) }
    }
    #endif
}

/// Private files avoid pipe deadlocks and unbounded output buffering. Cancelling
/// a task signals the helper; no credentials are needed for saved-score reads.
enum SimilarityHelper {
    static func request(configuration: SimilarityConfiguration, command: String, input: Data, arguments: [String] = []) async throws -> Data {
        let runner = SimilarityHelperProcess()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.run(configuration: configuration, command: command, input: input, arguments: arguments)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { runner.cancel() })
    }
}

private final class SimilarityHelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }
    func run(configuration: SimilarityConfiguration, command: String, input: Data, arguments: [String]) throws -> Data {
        let manager = FileManager.default
        let directory = configuration.temporaryDirectory.appendingPathComponent("query-\(UUID().uuidString)")
        try CloudDriveFiles.privateDirectory(directory)
        defer { try? manager.removeItem(at: directory) }
        let request = directory.appendingPathComponent("request.json"), output = directory.appendingPathComponent("response.json"), errors = directory.appendingPathComponent("error.txt")
        try input.write(to: request); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        for url in [output, errors] { manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let child = Process(); child.executableURL = configuration.executable
        child.arguments = [command] + (arguments.isEmpty ? ["--request-file", request.path] : arguments)
        child.environment = configuration.environment; child.standardInput = FileHandle.nullDevice
        child.standardOutput = out; child.standardError = err
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() } catch { lock.unlock(); throw error }
        child.waitUntilExit()
        lock.lock(); let stopped = cancelled; process = nil; lock.unlock()
        if stopped { throw CancellationError() }
        guard child.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: errors); defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_384) ?? Data()
            throw CloudDriveError.message(String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "Saved scores could not be loaded.")
        }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 32 * 1024 * 1024 else { throw CloudDriveError.message("This score row is too large to display. Narrow the scan scope.") }
        return try Data(contentsOf: output)
    }
}
