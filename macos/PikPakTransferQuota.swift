import Foundation
import Combine

struct PikPakTransferQuota: Decodable, Equatable {
    let cloudDownload: StorageQuota?
    let downstream: StorageQuota?
    let upload: StorageQuota?
    var dailyDownstream: StorageQuota? = nil
    var connectedApps: PikPakTrafficCounters? = nil

    func counters(for kind: PikPakCredentialKind) -> PikPakTrafficCounters {
        if kind == .personalAccessToken { return connectedApps ?? .unavailable }
        return PikPakTrafficCounters(cloudDownload: cloudDownload, downstream: downstream,
                                    upload: upload, dailyDownstream: dailyDownstream)
    }
}

struct PikPakTrafficCounters: Decodable, Equatable {
    let cloudDownload: StorageQuota?
    let downstream: StorageQuota?
    let upload: StorageQuota?
    var dailyDownstream: StorageQuota? = nil
    static let unavailable = Self(cloudDownload: nil, downstream: nil, upload: nil)
}

struct PikPakQuotaSnapshot: Decodable, Equatable {
    let accountId: String
    let total: UInt64
    let used: UInt64
    let transfer: PikPakTransferQuota

    var storage: StorageQuota { StorageQuota(total: total, used: used) }
}

/// One short metadata helper per account workspace. It never takes ownership
/// of the Browser or transfer process, and uses the existing refresh-token lock.
@MainActor
final class PikPakTransferQuotaMonitor: ObservableObject {
    @Published private(set) var snapshot: PikPakQuotaSnapshot?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private var lastAttempt: Date?
    private var accountID: String?
    private var connectionID: UUID?
    private var generation = UUID()
    private var request: PikPakAccountVerifier?
    private let now: () -> Date
    var processIdentifier: Int32? { request?.processIdentifier }

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func clear() {
        generation = UUID()
        request?.cancel()
        request = nil
        snapshot = nil
        updatedAt = nil
        lastAttempt = nil
        accountID = nil
        connectionID = nil
        isRefreshing = false
        error = nil
    }

    func unavailable() {
        error = "Could not refresh PikPak quotas. Try again."
    }

    @discardableResult
    func refresh(accountID: String, connectionID: UUID? = nil, force: Bool = false,
                 load: () async throws -> PikPakQuotaSnapshot) async -> PikPakQuotaSnapshot? {
        if self.accountID != accountID || self.connectionID != connectionID {
            clear()
            self.accountID = accountID
            self.connectionID = connectionID
        }
        guard !isRefreshing else { return nil }
        if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < 60 { return nil }
        let current = generation
        isRefreshing = true
        lastAttempt = now()
        error = nil
        defer { if current == generation { isRefreshing = false } }
        do {
            let result = try await load()
            try Task.checkCancellation()
            guard current == generation else { return nil }
            guard !accountID.isEmpty, result.accountId == accountID else { throw PikPakAccountError.accountMismatch }
            snapshot = result
            updatedAt = now()
            return result
        } catch {
            guard current == generation, !Task.isCancelled else { return nil }
            // Retain the last successful snapshot, explicitly marked stale.
            self.error = "Could not refresh PikPak quotas. The last update is shown."
            if snapshot == nil { self.error = "Could not load PikPak quotas. Try again." }
            return nil
        }
    }

    @discardableResult
    func refresh(engineURL: URL, environment: [String: String], accountID: String,
                 connectionID: UUID? = nil, force: Bool = false) async -> PikPakQuotaSnapshot? {
        await refresh(accountID: accountID, connectionID: connectionID, force: force) {
            let reader = PikPakAccountVerifier()
            request = reader
            defer { if request === reader { request = nil } }
            let data = try await reader.quota(engineURL: engineURL, environment: environment)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(PikPakQuotaSnapshot.self, from: data)
        }
    }
}
