import Foundation
import Combine

struct PikPakManagedFile: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: UInt64
    var parentId = ""
    var modifiedTime = ""
    var trashedTime = ""

    init(id: String, name: String, isFolder: Bool, size: UInt64, parentId: String = "") {
        self.id = id; self.name = name; self.isFolder = isFolder; self.size = size; self.parentId = parentId
    }
}

struct PikPakCloudTask: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let fileName: String
    let fileId: String
    let phase: String
    let progress: Double
    let size: UInt64
    let message: String
    let createdTime: String
    var title: String { !fileName.isEmpty ? fileName : (!name.isEmpty ? name : "Cloud download") }
    var isComplete: Bool { phase == "PHASE_TYPE_COMPLETE" }
    var isFailed: Bool { phase == "PHASE_TYPE_ERROR" }
    var hasFileCountLimit: Bool {
        message == PikPakManagementError.taskFileLimitCode || PikPakManagementError.fromHelper(message).isTaskFileLimit
    }
    var isActive: Bool { !isComplete && !isFailed && phase != "PHASE_TYPE_PAUSED" }
    var status: String {
        switch phase {
        case "PHASE_TYPE_COMPLETE": return "Saved to PikPak"
        case "PHASE_TYPE_ERROR": return "Failed"
        case "PHASE_TYPE_RUNNING": return "Downloading to PikPak"
        case "PHASE_TYPE_PAUSED": return "Paused"
        default: return "Waiting"
        }
    }
}

struct PikPakOwnedShare: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let url: String
    let passCode: String
    let status: String
    let expiresAt: String
    let createdTime: String
    let views: UInt64
    let saves: UInt64
    let size: UInt64
    var displayTitle: String { title.isEmpty ? "Shared items" : title }
    var shareURL: URL? {
        guard let value = URL(string: url), value.scheme == "https",
              let host = value.host, host == "mypikpak.com" || host.hasSuffix(".mypikpak.com") else { return nil }
        return value
    }
    var copyText: String { passCode.isEmpty ? url : "\(url)\nPasscode: \(passCode)" }
    var expirationLabel: String {
        if let date = PikPakManagementDate.parse(expiresAt) { return date.formatted(date: .abbreviated, time: .omitted) }
        return expiresAt.isEmpty ? "No expiry reported" : expiresAt
    }
}

enum PikPakManagementDate {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

struct PikPakConnectionDetails: Decodable, Equatable {
    let kind: String
    let expiresAt: Double?
    let permissions: [String]?
    let canPermanentlyDelete: Bool
    var expiry: Date? { expiresAt.map(Date.init(timeIntervalSince1970:)) }
    static let permissionNames: [(String, String)] = [
        ("files:read", "Read files"), ("files:write", "Write files"),
        ("files:manage", "Move to Trash and restore"), ("cloud_download", "Cloud downloads"),
        ("share", "Create and manage shares"), ("account", "Account settings")
    ]
}

struct PikPakManagementResponse: Decodable {
    let accountId: String
    var nextPageToken: String?
    var tasks: [PikPakCloudTask]?
    var shares: [PikPakOwnedShare]?
    var files: [PikPakManagedFile]?
    var task: PikPakCloudTask?
    var share: PikPakOwnedShare?
    var profile: PikPakAccountProfile?
    var credential: PikPakConnectionDetails?
    var ok: Bool?
}

struct PikPakManagementContext {
    let identity: UUID
    let accountID: String
    let engineURL: URL
    let environment: [String: String]
    let credentialKind: PikPakCredentialKind
}

struct PikPakCloudTaskFailure {
    let source: String
    let reason: PikPakManagementError
    var requiresDifferentLink: Bool { reason.isTaskFileLimit }
    var isUncertain: Bool { !reason.isDefiniteRejection }
    var title: String {
        requiresDifferentLink ? PikPakManagementError.taskFileLimitTitle : isUncertain ? "Check whether the task was created" : "PikPak could not create this task"
    }
    var message: String { requiresDifferentLink ? PikPakManagementError.taskFileLimitMessage : reason.localizedDescription }
    var recovery: String {
        if requiresDifferentLink { return PikPakManagementError.taskFileLimitRecovery }
        return isUncertain ? "Refresh Cloud Downloads before trying again; PikPak may have accepted the request." : "Review the link and the reported problem before submitting again."
    }
    var summary: String { "\(message) \(recovery)" }
    func applies(to link: String) -> Bool { Self.sourceKey(source) == Self.sourceKey(link) }
    private static func sourceKey(_ link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // Changing a torrent's display name or trackers does not reduce its file count.
        if let url = URLComponents(string: trimmed), url.scheme?.lowercased() == "magnet",
           let hash = url.queryItems?.first(where: { $0.name.lowercased() == "xt" && $0.value?.lowercased().hasPrefix("urn:btih:") == true })?.value {
            return hash.lowercased()
        }
        return trimmed
    }
}

/// A separate account-bound model keeps browser navigation and file previews
/// stable while management pages refresh. Mutations are never retried here.
@MainActor
final class PikPakManagementModel: ObservableObject {
    @Published private(set) var tasks: [PikPakCloudTask] = []
    @Published private(set) var shares: [PikPakOwnedShare] = []
    @Published private(set) var trash: [PikPakManagedFile] = []
    @Published private(set) var details: PikPakConnectionDetails?
    @Published private(set) var profile: PikPakAccountProfile?
    @Published private(set) var isLoading = false
    @Published private(set) var hasListError = false
    @Published private(set) var isMutating = false
    @Published private(set) var isConfirmingEmptyTrash = false
    @Published private(set) var isLoadingAccount = false
    @Published private(set) var accountError: String?
    @Published private(set) var error: String?
    @Published private(set) var cloudTaskFailure: PikPakCloudTaskFailure?
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsPending = false
    @Published private(set) var updatedAt: Date?
    @Published private(set) var revision = UUID()
    private(set) var context: PikPakManagementContext?
    private var pageTokens: [Int: String] = [:]
    private var seenTokens: [Int: Set<String>] = [:]
    private var readers: [UUID: PikPakAccountVerifier] = [:]
    private var generation = UUID()
    private var trashReadRevision = UUID()
    private var taskReadRevision = UUID()
    private var removedTaskIDs = Set<String>()
    private var pendingConfirmationID: UUID?
    private var handledConfirmationIDs = Set<UUID>()
    private var loadingSection: Int?
    private var trashRefreshTask: Task<Void, Never>?
    private var pendingEmptyTrash: (revision: UUID, success: String)?
    private var confirmedEmptyTrashNotice: String?
    var onFilesChanged: (() -> Void)?
    var onMutationState: ((Bool) -> Void)?
    #if FINDER_WORKSPACE_TESTS
    var fixture: (([String: Any]) async throws -> Data)?
    #endif
    var connected: Bool { context != nil }
    var canPermanentlyDelete: Bool { context?.credentialKind == .desktopOAuth }
    var hasActiveCloudTasks: Bool { tasks.contains(where: \.isActive) }
    var hasPendingEmptyTrash: Bool { pendingEmptyTrash != nil }
    var processIdentifiers: [Int32] { readers.values.compactMap(\.processIdentifier) }

    func configure(_ context: PikPakManagementContext?) {
        guard self.context?.identity != context?.identity || self.context?.accountID != context?.accountID
            || self.context?.credentialKind != context?.credentialKind else { self.context = context; return }
        clear()
        self.context = context
    }

    func clear() {
        trashRefreshTask?.cancel(); trashRefreshTask = nil; loadingSection = nil
        generation = UUID(); revision = UUID()
        readers.values.forEach { $0.cancel() }; readers.removeAll()
        context = nil; tasks = []; shares = []; trash = []; details = nil; profile = nil
        pageTokens = [:]; seenTokens = [:]; isLoading = false; isMutating = false; isLoadingAccount = false; accountError = nil
        error = nil; hasListError = false; cloudTaskFailure = nil; notice = nil; updatedAt = nil
        pendingEmptyTrash = nil; confirmedEmptyTrashNotice = nil
        taskReadRevision = UUID(); removedTaskIDs = []; pendingConfirmationID = nil
        handledConfirmationIDs = []
        isConfirmingEmptyTrash = false; noticeIsPending = false
        onMutationState?(false)
    }

    func hasMore(_ section: Int) -> Bool { !(pageTokens[section] ?? "").isEmpty }

    /// Browser Undo/Redo runs in another engine lane. Reconcile the visible
    /// Trash immediately, then reload without accepting a pre-Undo listing.
    func fileTrashChanged(_ changes: [FinderFileMutation]) {
        let changes = changes.filter { $0.kind == .trash }
        guard !changes.isEmpty else { return }
        trashReadRevision = UUID()
        if pendingEmptyTrash != nil {
            pendingEmptyTrash = nil
            notice = "Empty Trash requested. Refresh to check the current Trash."
            noticeIsPending = true
        } else if notice == confirmedEmptyTrashNotice {
            dismissNotice()
        }
        let restored = Set(changes.filter { $0.after == "false" }.map(\.fileId))
        trash.removeAll { restored.contains($0.id) }
        guard connected, pageTokens[6] != nil || loadingSection == 6 else { return }
        trashRefreshTask?.cancel()
        let current = generation, revision = trashReadRevision
        trashRefreshTask = Task { [weak self] in
            guard let self else { return }
            while self.isLoading || self.isMutating {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard self.generation == current, self.trashReadRevision == revision else { return }
            }
            guard !Task.isCancelled, self.generation == current, self.trashReadRevision == revision else { return }
            await self.load(6, quietly: true)
        }
    }

    func load(_ section: Int, more: Bool = false, quietly: Bool = false) async {
        guard connected, !isLoading, !isMutating else { return }
        let operation: String
        switch section { case 4: operation = "list_tasks"; case 5: operation = "list_shares"; case 6: operation = "list_trash"; default: return }
        if more && !hasMore(section) { return }
        let current = generation, trashRevision = trashReadRevision, taskRevision = taskReadRevision
        isLoading = true
        loadingSection = section
        if !quietly { error = nil; hasListError = false }
        defer { if current == generation { isLoading = false; loadingSection = nil } }
        do {
            let token = more ? pageTokens[section] ?? "" : ""
            let result = try await AutomaticRecovery.read {
                guard current == self.generation else { throw PikPakAccountError.accountMismatch }
                guard section != 4 || taskRevision == self.taskReadRevision else { throw PikPakAccountError.accountMismatch }
                do {
                    return try await self.request(["operation":operation, "page_token":token])
                } catch {
                    // A superseded read must not keep retrying an outage after
                    // a confirmed task removal has made its result obsolete.
                    guard section != 4 || taskRevision == self.taskReadRevision else { throw PikPakAccountError.accountMismatch }
                    throw error
                }
            }
            guard current == generation else { return }
            guard section != 6 || trashRevision == trashReadRevision else { return }
            guard section != 4 || taskRevision == taskReadRevision else { return }
            let next = result.nextPageToken ?? ""
            let seen = more ? seenTokens[section] ?? [] : []
            guard next.isEmpty || (next != token && !seen.contains(next)) else {
                throw PikPakManagementError.message("PikPak repeated a page. Refresh to continue safely.")
            }
            switch section {
            case 4: guard let rows = result.tasks else { throw PikPakAccountError.unavailable }
                let previous = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.isComplete) })
                let visibleRows = rows.filter { !removedTaskIDs.contains($0.id) }
                if visibleRows.contains(where: { $0.isComplete && previous[$0.id] == false }) { onFilesChanged?() }
                tasks = merge(more ? tasks : [], visibleRows)
            case 5: guard let rows = result.shares else { throw PikPakAccountError.unavailable }
                shares = merge(more ? shares : [], rows)
            default: guard let rows = result.files else { throw PikPakAccountError.unavailable }
                trash = merge(more ? trash : [], rows)
            }
            pageTokens[section] = next; seenTokens[section] = seen.union(next.isEmpty ? [] : [next])
            if section == 6 && !more { reconcileEmptyTrash(rows: trash, next: next) }
            updatedAt = Date(); error = nil; hasListError = false
        } catch is CancellationError { }
        catch {
            if current == generation && (section != 6 || trashRevision == trashReadRevision)
                && (section != 4 || taskRevision == taskReadRevision) {
                self.error = error.localizedDescription; hasListError = true
            }
        }
    }

    func loadAccount() async {
        guard connected, !isLoadingAccount else { return }
        let current = generation
        isLoadingAccount = true; accountError = nil
        defer { if current == generation { isLoadingAccount = false } }
        do {
            let response = try await AutomaticRecovery.read {
                guard current == self.generation else { throw PikPakAccountError.accountMismatch }
                return try await self.request(["operation":"account_details"])
            }
            guard current == generation else { return }
            details = response.credential; profile = response.profile
        } catch is CancellationError { }
        catch { if current == generation { self.accountError = error.localizedDescription } }
    }

    func pickFiles(parent: String, pageToken: String = "") async throws -> PikPakManagementResponse {
        let current = generation
        return try await AutomaticRecovery.read {
            guard current == self.generation else { throw PikPakAccountError.accountMismatch }
            return try await self.request(["operation":"pick_files", "parent_id":parent, "page_token":pageToken])
        }
    }

    @discardableResult
    func submitConfirmedMutation(_ operation: String, values: [String: Any], section: Int, success: String,
                                 expectedRevision: UUID, confirmationID: UUID) -> Task<PikPakManagementResponse?, Never>? {
        guard connected, revision == expectedRevision, !handledConfirmationIDs.contains(confirmationID) else { return nil }
        handledConfirmationIDs.insert(confirmationID)
        guard !isMutating, pendingConfirmationID == nil else { return nil }
        pendingConfirmationID = confirmationID
        return Task { [weak self] in
            guard let self, self.revision == expectedRevision, self.pendingConfirmationID == confirmationID else { return nil }
            self.pendingConfirmationID = nil
            return await self.mutate(operation, values: values, section: section, success: success)
        }
    }

    @discardableResult
    func mutate(_ operation: String, values: [String: Any], section: Int, success: String) async -> PikPakManagementResponse? {
        guard connected, !isMutating, pendingConfirmationID == nil else { return nil }
        if operation == "create_task", let failure = cloudTaskFailure, failure.requiresDifferentLink,
           failure.applies(to: values["url"] as? String ?? "") {
            error = failure.summary
            return nil
        }
        let current = generation
        if ["create_task", "retry_task", "remove_task"].contains(operation) { taskReadRevision = UUID() }
        if ["restore_trash", "delete_trash", "empty_trash"].contains(operation) {
            trashReadRevision = UUID()
            pendingEmptyTrash = nil
            trashRefreshTask?.cancel(); trashRefreshTask = nil
        }
        let trashRevision = trashReadRevision
        isMutating = true; onMutationState?(true); error = nil; dismissNotice()
        if operation == "create_task" { cloudTaskFailure = nil }
        var input = values; input["operation"] = operation
        var response: PikPakManagementResponse?
        do {
            let result = try await request(input)
            guard current == generation else { return nil }
            // Do not display success for an incomplete/unknown helper reply.
            guard result.ok == true || result.task != nil || result.share != nil else { throw PikPakAccountError.unavailable }
            response = result
            if operation == "remove_task" {
                let ids = values["ids"] as? [String] ?? [values["id"] as? String ?? ""]
                removedTaskIDs.formUnion(ids.filter { !$0.isEmpty })
                tasks.removeAll { removedTaskIDs.contains($0.id) }
            }
            if operation == "empty_trash" {
                notice = "Empty Trash requested. Checking PikPak…"
                noticeIsPending = true
                if trashRevision == trashReadRevision {
                    pendingEmptyTrash = (trashRevision, success)
                    isConfirmingEmptyTrash = true
                    await confirmEmptyTrash(generation: current, revision: trashRevision)
                } else {
                    notice = "Empty Trash requested. Refresh to check the current Trash."
                }
            } else {
                notice = success
            }
            if ["create_task", "restore_trash", "delete_trash", "empty_trash"].contains(operation) { onFilesChanged?() }
        } catch is CancellationError { }
        catch {
            if current == generation {
                let reason = (error as? PikPakManagementError) ?? .message(PikPakManagementError.safeMessage(error.localizedDescription))
                self.error = reason.localizedDescription
                if operation == "create_task" {
                    let failure = PikPakCloudTaskFailure(source: values["url"] as? String ?? "", reason: reason)
                    cloudTaskFailure = failure
                    self.error = failure.summary
                } else if operation == "create_share" && !reason.isDefiniteRejection {
                    self.error! += " Refresh the list before trying again; PikPak may have accepted the request."
                }
            }
        }
        guard current == generation else { return nil }
        isConfirmingEmptyTrash = false
        isMutating = false; onMutationState?(false)
        if response != nil && operation != "empty_trash" { await load(section, quietly: true) }
        return response
    }

    /// Empty Trash acknowledges a request before its deletion/listing settles.
    /// Retry reads only, and preserve current rows until PikPak confirms empty.
    private func confirmEmptyTrash(generation current: UUID, revision: UUID) async {
        let delays: [UInt64] = [0, 250_000_000, 750_000_000, 1_500_000_000, 2_500_000_000]
        do {
            for delay in delays {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                try Task.checkCancellation()
                guard current == generation, revision == trashReadRevision,
                      pendingEmptyTrash?.revision == revision else { return }
                // AutomaticRecovery.read retries indefinitely; confirmation
                // needs a bounded number of reads and an explicit pending state.
                let result = try await request(["operation":"list_trash", "page_token":""])
                guard current == generation, revision == trashReadRevision else { return }
                guard let rows = result.files else { throw PikPakAccountError.unavailable }
                let next = result.nextPageToken ?? ""
                trash = merge([], rows)
                pageTokens[6] = next; seenTokens[6] = next.isEmpty ? [] : [next]
                updatedAt = Date(); error = nil; hasListError = false
                reconcileEmptyTrash(rows: rows, next: next)
                if pendingEmptyTrash == nil { return }
            }
        } catch is CancellationError { }
        catch {
            if current == generation, revision == trashReadRevision {
                self.error = "PikPak accepted the Empty Trash request, but its completion could not be checked. "
                    + PikPakManagementError.safeMessage(error.localizedDescription)
                    + " Refresh Trash to check again."
                hasListError = true
            }
        }
        if current == generation, revision == trashReadRevision, pendingEmptyTrash != nil {
            notice = "Empty Trash requested. PikPak has not confirmed completion yet. Refresh to check again."
            noticeIsPending = true
        }
    }

    private func reconcileEmptyTrash(rows: [PikPakManagedFile], next: String) {
        let empty = rows.isEmpty && next.isEmpty
        if let pending = pendingEmptyTrash, pending.revision == trashReadRevision {
            if empty {
                pendingEmptyTrash = nil
                notice = pending.success; confirmedEmptyTrashNotice = pending.success
                noticeIsPending = false
            }
        } else if !empty, notice == confirmedEmptyTrashNotice {
            dismissNotice()
        }
    }

    func dismissNotice() { notice = nil; noticeIsPending = false; confirmedEmptyTrashNotice = nil }

    private func request(_ values: [String: Any]) async throws -> PikPakManagementResponse {
        guard let context else { throw PikPakAccountError.needsSignIn }
        let current = generation
        var input = values; input["account_id"] = context.accountID
        let data: Data
        #if FINDER_WORKSPACE_TESTS
        if let fixture { data = try await fixture(input) }
        else { data = try await run(context, input: input) }
        #else
        data = try await run(context, input: input)
        #endif
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(PikPakManagementResponse.self, from: data)
        guard response.accountId == context.accountID else { throw PikPakAccountError.accountMismatch }
        return response
    }

    private func run(_ context: PikPakManagementContext, input: [String: Any]) async throws -> Data {
        let id = UUID(), reader = PikPakAccountVerifier(); readers[id] = reader
        defer { readers.removeValue(forKey: id) }
        return try await reader.management(engineURL: context.engineURL, environment: context.environment,
            input: JSONSerialization.data(withJSONObject: input))
    }

    private func merge<T: Identifiable>(_ old: [T], _ new: [T]) -> [T] where T.ID: Hashable {
        var rows = old, positions = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, $0.offset) })
        for row in new {
            if let index = positions[row.id] { rows[index] = row }
            else { positions[row.id] = rows.count; rows.append(row) }
        }
        return rows
    }
}
