import AppKit
import Combine
import Foundation

final class SimilarityTreeNode: NSObject {
    let id: String
    let name: String
    let path: String
    let file: SimilarityFile?
    var group: SimilarityResultGroup?
    var children: [SimilarityTreeNode] = []
    var fileCount = 0
    init(id: String, name: String, path: String, file: SimilarityFile? = nil) {
        self.id = id; self.name = name; self.path = path; self.file = file
    }
}

struct SimilarityResultGroup: Identifiable {
    let id: String
    let members: [SimilarityFile]
    let minimumScore: Double?
    let identical: Bool
    var hasRemovedMembers = false
    var strengthLabel: String {
        identical ? "Identical content" : String(format: hasRemovedMembers ? "Every pair ≥ %.1f%%" : "Weakest pair %.1f%%", (minimumScore ?? 0) * 100)
    }
}

/// A new ID makes a repeated Expand/Collapse All click an explicit command.
struct SimilarityGroupExpansion: Equatable {
    let id = UUID()
    let expanded: Bool
}

private struct SimilaritySavedGroups: Decodable {
    struct Group: Decodable {
        let id: String
        let fileIds: [String]
        let minimumScore: Double?
        let identical: Bool
    }
    let runId: String
    let resultRevision: UInt64
    let minimumScore: Double
    let groups: [Group]
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

    func filteredRoots(_ query: String, excluding: Set<String> = []) -> [SimilarityTreeNode] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || !excluding.isEmpty else { return roots }
        func filter(_ node: SimilarityTreeNode) -> SimilarityTreeNode? {
            if let file = node.file {
                return !excluding.contains(file.id) && (query.isEmpty || node.path.localizedStandardContains(query)) ? node : nil
            }
            if excluding.isEmpty && node.path.localizedStandardContains(query) { return node }
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
    @Published private(set) var groups: [SimilarityResultGroup] = []
    @Published private(set) var selectedGroupID: String?
    @Published private(set) var isGrouping = false
    @Published private(set) var groupingError: String?
    @Published private(set) var groupExpansion: SimilarityGroupExpansion?
    @Published private(set) var trashedIDs: Set<String> = []
    @Published private(set) var trashingIDs: Set<String> = []
    @Published var fileActionMessage: String?
    @Published var fileActionError: String?
    @Published var browseGroups = true { didSet { filterTree() } }
    @Published var query = "" { didSet { filterTree() } }
    @Published var minimumScore = 0.9 { didSet { if oldValue != minimumScore { filterMatches(); regroup() } } }
    @Published var identicalOnly = false { didSet { if oldValue != identicalOnly { filterMatches(); regroup() } } }
    @Published var showAllScores = false { didSet { filterMatches() } }
    private var report: SimilarityReport?
    private var configuration: SimilarityConfiguration?
    private var generation = UUID()
    private var requestID = UUID()
    private var indexTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var groupingTask: Task<Void, Never>?
    private var groupingID = UUID()
    private var groupCache: [String: [SimilarityResultGroup]] = [:]
    private var groupCacheOrder: [String] = []
    private var rows: [String: SimilarityScoreRow] = [:]
    private var rowOrder: [String] = []
    private var allRelated: [SimilarityRelatedFile] = []
    private var unfilteredGroups: [SimilarityResultGroup] = []
    var selectedFile: SimilarityFile? { selectedID.flatMap { index?.byID[$0] } }
    var selectedGroup: SimilarityResultGroup? { groups.first { $0.id == selectedGroupID } }
    var selectedNodeID: String? { selectedID ?? selectedGroupID }
    var groupedFileCount: Int { groups.reduce(0) { $0 + $1.members.count } }
    var availableFileCount: Int { index?.files.filter { !trashedIDs.contains($0.id) && ($0.state == nil || $0.state == "ready") }.count ?? 0 }
    var hasSavedComparisons: Bool { report?.runId != nil && report?.resultRevision != nil }
    var visibleFileCount: Int { max(0, (index?.files.count ?? 0) - trashedIDs.count) }
    var sessionToken: UUID { generation }
    private(set) var allowsSizeBasedCleanup = true

    func keepSmallestPlan(groupID: String? = nil) -> SimilarityKeepSmallestPlan? {
        guard allowsSizeBasedCleanup, !isIndexing, !isGrouping, groupingError == nil, trashingIDs.isEmpty else { return nil }
        let scope = groupID.map { id in groups.filter { $0.id == id } } ?? groups
        let plan = SimilarityKeepSmallestPlan(groups: scope, session: generation,
            minimumScore: minimumScore, identicalOnly: identicalOnly)
        return plan.removals.isEmpty ? nil : plan
    }

    func validateKeepSmallest(_ plan: SimilarityKeepSmallestPlan) throws {
        guard allowsSizeBasedCleanup, generation == plan.session, !isIndexing, !isGrouping, groupingError == nil,
              minimumScore == plan.minimumScore, identicalOnly == plan.identicalOnly else {
            throw CloudDriveError.message("The similarity groups changed. Review the current groups and try again.")
        }
        let current = SimilarityKeepSmallestPlan(groups: groups.filter { plan.groupIDs.contains($0.id) },
            session: generation, minimumScore: minimumScore, identicalOnly: identicalOnly)
        guard current.groupIDs == plan.groupIDs, current.removalIDs == plan.removalIDs,
              Set(current.keepers.map(\.id)) == Set(plan.keepers.map(\.id)), !plan.removals.isEmpty,
              (plan.keepers + plan.removals).allSatisfy({ file in
                  guard let stored = index?.byID[file.id] else { return false }
                  return !trashedIDs.contains(file.id) && stored.bytes == file.bytes
                      && SimilarityKeepSmallestPlan.originalID(stored) == SimilarityKeepSmallestPlan.originalID(file)
              }) else {
            throw CloudDriveError.message("These files changed since the groups were displayed. Review the results and try again.")
        }
    }

    func keepSmallest(_ plan: SimilarityKeepSmallestPlan, destination: String = "Trash",
                     using operation: @escaping (SimilarityKeepSmallestPlan) async throws -> Set<String>) {
        guard trashingIDs.isEmpty else { return }
        do { try validateKeepSmallest(plan) }
        catch { fileActionError = error.localizedDescription; return }
        trashingIDs = plan.removalIDs; fileActionError = nil; fileActionMessage = nil
        Task { [weak self] in
            guard let self, self.generation == plan.session else { return }
            do {
                let confirmed = try await operation(plan).intersection(plan.removalIDs)
                guard self.generation == plan.session else { return }
                self.setTrashedIDs(confirmed, true)
                if confirmed == plan.removalIDs {
                    self.fileActionMessage = "Kept \(plan.keepers.count) smallest \(plan.keepers.count == 1 ? "file" : "files"). Moved \(confirmed.count) to \(destination)."
                    if plan.groupIDs.count == 1, let keeper = plan.keepers.first {
                        self.query = ""; self.showAllFiles(); self.select(keeper.id)
                    }
                } else {
                    self.fileActionError = "Moved \(confirmed.count) of \(plan.removals.count) files to \(destination). The drive did not confirm the others; they remain in the results. All kept files were preserved."
                }
            } catch {
                guard self.generation == plan.session else { return }
                self.fileActionError = FileSearchIndex.redacted(error.localizedDescription)
            }
            self.trashingIDs = []
        }
    }

    func moveToTrash(_ file: SimilarityFile, using operation: @escaping (SimilarityFile) async throws -> Void) {
        guard index?.byID[file.id] != nil, !trashedIDs.contains(file.id), trashingIDs.isEmpty else { return }
        let token = generation
        trashingIDs.insert(file.id); fileActionError = nil; fileActionMessage = nil
        Task { [weak self] in
            guard let self, self.generation == token else { return }
            do {
                try await operation(file)
                guard self.generation == token else { return }
                self.setTrashed(file.id, true)
                self.fileActionMessage = "\(file.name) moved to Trash."
            } catch {
                guard self.generation == token else { return }
                self.fileActionError = FileSearchIndex.redacted(error.localizedDescription)
            }
            self.trashingIDs.remove(file.id)
        }
    }

    /// Keep the saved matrix immutable. Trash/Undo only change which files are
    /// offered for review, including late score rows and cached regrouping.
    func setTrashed(_ id: String, _ trashed: Bool) {
        setTrashedIDs([id], trashed)
    }
    func setTrashedIDs(_ ids: Set<String>, _ trashed: Bool) {
        let ids = ids.filter { index?.byID[$0] != nil }
        guard !ids.isEmpty else { return }
        if trashed { trashedIDs.formUnion(ids) } else { trashedIDs.subtract(ids) }
        if trashed, let selectedID, ids.contains(selectedID) { select(nil) }
        if !trashed { fileActionMessage = nil }
        // A Trash acknowledgement can arrive while the threshold's new groups
        // are loading. Keep that loading state until the new groups arrive.
        let regrouping = isGrouping
        filterMatches(); applyGroups(unfilteredGroups)
        isGrouping = regrouping
    }
    func setCloudFilesTrashed(_ ids: Set<String>, _ trashed: Bool) {
        guard !ids.isEmpty else { return }
        setTrashedIDs(Set((index?.files ?? []).filter { $0.cloudId.map(ids.contains) == true }.map(\.id)), trashed)
    }

    func reset() {
        generation = UUID(); requestID = UUID()
        indexTask?.cancel(); queryTask?.cancel(); matchTask?.cancel(); searchTask?.cancel(); groupingTask?.cancel()
        indexTask = nil; queryTask = nil; searchTask = nil
        index = nil; roots = []; selectedID = nil; related = []; allRelated = []; rows = [:]; rowOrder = []
        isLoading = false; isIndexing = false; error = nil; unavailable = [:]; omitted = 0
        groupingID = UUID(); groups = []; selectedGroupID = nil; isGrouping = false; groupingError = nil
        groupExpansion = nil
        trashedIDs = []; trashingIDs = []; unfilteredGroups = []; fileActionMessage = nil; fileActionError = nil
        groupCache = [:]; groupCacheOrder = []
        report = nil; configuration = nil; query = ""
        minimumScore = 0.9; identicalOnly = false; showAllScores = false; browseGroups = true
    }
    func load(_ report: SimilarityReport, configuration: SimilarityConfiguration?, allowsSizeBasedCleanup: Bool = true) {
        reset(); self.report = report; self.configuration = configuration
        self.allowsSizeBasedCleanup = allowsSizeBasedCleanup
        minimumScore = report.threshold; identicalOnly = false; showAllScores = false; isIndexing = true
        browseGroups = report.status != "cancelled" && (report.runId != nil || !report.groups.isEmpty)
        let token = generation
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { SimilarityResultIndex.build(report) }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.index = index; self.roots = index.roots; self.isIndexing = false
            self.regroup(immediate: true)
            // Let the user choose the reference file instead of fetching a
            // potentially large cloud original as a side effect of finishing.
        }
    }
    func select(_ id: String?) {
        if let id, trashedIDs.contains(id) { return }
        selectedGroupID = nil
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
    func selectNode(_ id: String?) {
        if let id, groups.contains(where: { $0.id == id }) {
            select(nil); selectedGroupID = id
        } else { select(id) }
    }
    func showAllFiles() {
        let first = selectedGroup?.members.first?.id
        browseGroups = false
        if let first { select(first) }
    }
    func setAllGroupsExpanded(_ expanded: Bool) {
        guard browseGroups, !isGrouping, !groups.isEmpty else { return }
        // Keep the selection visible after collapsing its containing group.
        if !expanded, let selectedID,
           let group = groups.first(where: { $0.members.contains(where: { $0.id == selectedID }) }) {
            selectNode(group.id)
        }
        groupExpansion = SimilarityGroupExpansion(expanded: expanded)
    }
    func setMinimumScoreFromSlider(_ value: Double) {
        guard value.isFinite else { return }
        // Snap the continuous slider to whole percentages without requesting
        // macOS's densely packed step marks. Never round saved measurements.
        minimumScore = min(1, max(0.05, (value * 100).rounded() / 100))
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
        related = allRelated.filter { !trashedIDs.contains($0.id) && (identicalOnly ? $0.identical : showAllScores || $0.identical || ($0.score.map { $0 >= minimumScore } ?? false)) }
    }
    private func filterTree() {
        searchTask?.cancel()
        guard let index else { return }
        let query = query, token = generation, groups = groups, grouped = browseGroups, excluded = trashedIDs
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
            let roots = await Task.detached(priority: .userInitiated) {
                grouped ? Self.groupRoots(groups, query: query) : index.filteredRoots(query, excluding: excluded)
            }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.roots = roots
        }
    }

    private nonisolated static func groupRoots(_ groups: [SimilarityResultGroup], query: String) -> [SimilarityTreeNode] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.enumerated().compactMap { number, group in
            // Keep the whole group visible when one member matches the search.
            guard search.isEmpty || group.members.contains(where: { $0.path.localizedStandardContains(search) }) else { return nil }
            let node = SimilarityTreeNode(id: group.id, name: "Group \(number + 1)", path: group.strengthLabel)
            node.group = group; node.fileCount = group.members.count
            node.children = group.members.map { SimilarityTreeNode(id: $0.id, name: $0.name, path: $0.path, file: $0) }
            return node
        }
    }

    func regroup(immediate: Bool = false) {
        groupingTask?.cancel(); groupingID = UUID(); groupingError = nil
        guard let index, let report else { return }
        let key = identicalOnly ? "identical" : String(minimumScore)
        if let cached = groupCache[key] { applyGroups(cached); return }
        if identicalOnly || !hasSavedComparisons || configuration == nil {
            let exact = index.exactGroups.sorted { $0.key < $1.key }.map { id, members in
                SimilarityResultGroup(id: "group:" + id, members: members.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, minimumScore: nil, identical: true)
            }
            applyGroups(exact); return
        }
        guard let configuration, let run = report.runId, let revision = report.resultRevision else { return }
        let token = groupingID, cutoff = minimumScore
        isGrouping = true
        groupingTask = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(nanoseconds: 220_000_000) }
                let input: [String: Any] = ["data_dir": configuration.dataDirectory.path, "run_id": run,
                    "result_revision": revision, "minimum_score": cutoff, "include_identical": !index.exactGroups.isEmpty]
                let output = try await SimilarityHelper.request(configuration: configuration, command: "similarity-groups",
                    input: JSONSerialization.data(withJSONObject: input))
                let groups = try await Task.detached(priority: .userInitiated) {
                    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let saved = try decoder.decode(SimilaritySavedGroups.self, from: output)
                    guard saved.runId == run, saved.resultRevision == revision, saved.minimumScore == cutoff else {
                        throw CloudDriveError.message("The returned groups belong to a different scan or threshold.")
                    }
                    return saved.groups.compactMap { group -> SimilarityResultGroup? in
                        let members = group.fileIds.compactMap { index.byScoreID[$0] }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                        guard members.count > 1 else { return nil }
                        return .init(id: "group:" + group.id, members: members, minimumScore: group.minimumScore, identical: group.identical)
                    }
                }.value
                guard let self, !Task.isCancelled, self.groupingID == token else { return }
                self.groupCache[key] = groups; self.groupCacheOrder.append(key)
                while self.groupCacheOrder.count > 5 { self.groupCache[self.groupCacheOrder.removeFirst()] = nil }
                self.applyGroups(groups)
            } catch {
                guard let self, !Task.isCancelled, self.groupingID == token else { return }
                self.isGrouping = false; self.groupingError = FileSearchIndex.redacted(error.localizedDescription)
                self.groups = []; self.selectedGroupID = nil; self.filterTree()
            }
        }
    }

    private func applyGroups(_ groups: [SimilarityResultGroup]) {
        let previousMember = selectedGroup?.members.first?.id
        unfilteredGroups = groups
        let groups = groups.compactMap { group -> SimilarityResultGroup? in
            let members = group.members.filter { !trashedIDs.contains($0.id) }
            guard members.count > 1 else { return nil }
            return .init(id: group.id, members: members, minimumScore: group.minimumScore, identical: group.identical,
                         hasRemovedMembers: members.count != group.members.count)
        }
        self.groups = groups; isGrouping = false; filterTree()
        if selectedID == nil, !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = browseGroups ? (previousMember.flatMap { file in groups.first { $0.members.contains { $0.id == file } } } ?? groups.first)?.id : nil
        }
    }
    #if FINDER_WORKSPACE_TESTS
    func setFixtureRow(_ row: SimilarityScoreRow) {
        rows[row.fileId] = row
        if let file = selectedFile, file.scoreID == row.fileId { apply(row, file: file) }
    }
    func setFixtureGroups(_ groups: [SimilarityResultGroup], at threshold: Double) {
        groupCache[String(threshold)] = groups
        if minimumScore == threshold { regroup(immediate: true) }
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
