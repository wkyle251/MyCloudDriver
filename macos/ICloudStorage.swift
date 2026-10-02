import Combine
import Foundation

enum ICloudStorageError: LocalizedError {
    case unavailable, timedOut, invalidResponse
    var errorDescription: String? {
        switch self {
        case .timedOut: return "iCloud storage did not respond. Try refreshing again."
        case .unavailable: return "iCloud storage is unavailable. Check your Apple Account in iCloud Storage settings."
        case .invalidResponse: return "macOS did not provide a readable iCloud storage value. View storage in System Settings."
        }
    }
}

/// brctl reports remaining account quota, not plan capacity or local disk space.
/// Accept only a personal account (or the older, single-account output format).
enum ICloudQuotaParser {
    static func remainingBytes(in output: String) throws -> UInt64 {
        let expression = try NSRegularExpression(pattern: #"^([0-9]+) bytes of quota remaining(?: in (personal|enterprise) account)?$"#)
        var personal: [UInt64] = [], legacy: [UInt64] = [], records = 0
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            records += 1
            let ns = line as NSString
            guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let bytes = UInt64(ns.substring(with: match.range(at: 1))), bytes <= UInt64(Int64.max) else {
                throw ICloudStorageError.invalidResponse
            }
            let account = match.range(at: 2)
            if account.location == NSNotFound { legacy.append(bytes) }
            else if ns.substring(with: account) == "personal" { personal.append(bytes) }
        }
        if personal.count == 1 && legacy.isEmpty { return personal[0] }
        if personal.isEmpty && legacy.count == 1 && records == 1 { return legacy[0] }
        throw ICloudStorageError.invalidResponse
    }
}

/// A short, read-only request to the system iCloud client. No credentials or
/// account database are read. Raw output is never published or logged.
@MainActor final class ICloudQuotaReader {
    private let executableURL: URL
    private let arguments: [String]
    private let timeoutNanoseconds: UInt64
    private var process: Process?
    private var deadline: Task<Void, Never>?
    private var timedOut = false
    var processIdentifier: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/brctl"), arguments: [String] = ["quota"],
         timeoutNanoseconds: UInt64 = 8_000_000_000) {
        self.executableURL = executableURL; self.arguments = arguments; self.timeoutNanoseconds = timeoutNanoseconds
    }
    func read() async throws -> UInt64 {
        try Task.checkCancellation()
        guard process == nil else { throw ICloudStorageError.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-Quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("quota")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw ICloudStorageError.unavailable
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = executableURL; child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["LANG"] = "C"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        process = child; timedOut = false
        defer { deadline?.cancel(); deadline = nil; process = nil }
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try child.run()
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0) } catch { return }
                        self?.timedOut = true; self?.cancel()
                    }
                } catch { continuation.resume(throwing: ICloudStorageError.unavailable) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        guard !timedOut else { throw ICloudStorageError.timedOut }
        guard code == 0 else { throw ICloudStorageError.unavailable }
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16_384 else { throw ICloudStorageError.invalidResponse }
        return try ICloudQuotaParser.remainingBytes(in: String(contentsOf: outputURL, encoding: .utf8))
    }
    func cancel() {
        guard let child = process, child.isRunning else { return }
        child.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

@MainActor final class ICloudStorageModel: ObservableObject {
    @Published private(set) var remainingBytes: UInt64?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    private let fetch: () async throws -> UInt64
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastAttempt: Date?

    init(fetch: (() async throws -> UInt64)? = nil) {
        if let fetch { self.fetch = fetch }
        else {
            self.fetch = { let reader = ICloudQuotaReader(); return try await reader.read() }
        }
    }
    @discardableResult func refresh(force: Bool = false) -> Task<Void, Never>? {
        guard !isRefreshing else { return task }
        // Reopening tabs must not repeatedly query the system service. Failed
        // requests retry sooner, while the refresh button always retries now.
        let interval: TimeInterval = errorMessage == nil ? 300 : 30
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval { return nil }
        let id = UUID(); generation = id; lastAttempt = Date()
        isRefreshing = true; errorMessage = nil; remainingBytes = nil; checkedAt = nil
        let request = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { isRefreshing = false; task = nil } }
            do {
                let bytes = try await fetch()
                try Task.checkCancellation()
                guard generation == id else { return }
                remainingBytes = bytes; checkedAt = Date()
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                errorMessage = (error as? ICloudStorageError)?.localizedDescription ?? ICloudStorageError.unavailable.localizedDescription
            }
        }
        task = request
        return request
    }
    func clear() {
        generation = UUID(); task?.cancel(); task = nil
        isRefreshing = false; remainingBytes = nil; checkedAt = nil; errorMessage = nil; lastAttempt = nil
    }
}
