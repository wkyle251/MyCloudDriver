import Foundation

/// Only an explicit rejection of the saved credential requires a new login.
/// HTTP 401 can instead describe an expired access token or an unrelated
/// request; HTTP 400 can be a client/configuration error. Neither proves that
/// the account's refresh credential is unusable.
enum PikPakSessionFailure {
    static func requiresSignIn(_ raw: String) -> Bool {
        for rawLine in raw.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if line.hasPrefix("error: ") { line.removeFirst(7) }
            if line.hasPrefix("pikpak session rejected: ") { return true }
            // Compatibility with older helpers and saved error presentations.
            guard line.hasPrefix("authentication failed: ") else { continue }
            let detail = String(line.dropFirst("authentication failed: ".count))
            if detail == "invalid_grant" || detail.hasPrefix("personal access token expired or revoked") { return true }
            if let start = detail.firstIndex(of: "{"),
               let body = try? JSONSerialization.jsonObject(with: Data(detail[start...].utf8)) as? [String: Any],
               detail.hasPrefix("status 400:") || detail.hasPrefix("status 401:") {
                if body["error"] as? String == "invalid_grant" || body["error_code"] as? Int == 4126 { return true }
            }
        }
        return false
    }
}

enum PikPakManagementError: LocalizedError {
    case message(String)
    case api(status: Int, code: String?, message: String)
    case rejected(String)

    static let taskFileLimitCode = "task_sub_task_num_limit"
    static let taskFileLimitTitle = "This link contains too many files"
    static let taskFileLimitMessage = "PikPak rejected this task because the source contains more files than it can process. Its published limit is 7,000 files per torrent."
    static let taskFileLimitRecovery = "Choose Download to Mac to select files and download them locally, then upload them to PikPak if needed. You can also use a different link with fewer files. PikPak currently cannot select individual files from a torrent."
    static let torrentHelpURL = URL(string: "https://mypikpak.com/en-US/help-center/save_files/torrent_magnet")!

    var isTaskFileLimit: Bool {
        if case .api(_, let code, _) = self { return code == Self.taskFileLimitCode }
        return false
    }
    var isDefiniteRejection: Bool {
        switch self {
        case .api(let status, _, _): return (400..<500).contains(status) && status != 408
        case .rejected: return true
        case .message: return false
        }
    }
    var errorDescription: String? {
        if isTaskFileLimit { return "\(Self.taskFileLimitTitle). \(Self.taskFileLimitMessage) \(Self.taskFileLimitRecovery)" }
        switch self {
        case .message(let message), .rejected(let message), .api(_, _, let message): return message
        }
    }
    var technicalDetails: String? {
        guard case .api(let status, let code, _) = self else { return nil }
        return "PikPak HTTP \(status)\(code.map { " · \($0)" } ?? "")"
    }

    /// Decode the helper's API error before shortening the visible message.
    /// HTTP 416 alone is not a file-count error; PikPak's service code identifies it.
    static func fromHelper(_ raw: String) -> Self {
        let raw = String(raw.prefix(65_536)).trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try! NSRegularExpression(pattern: #"(?m)^(?:error: )?API error ([0-9]{3}): "#)
        if let match = expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).last,
           let statusRange = Range(match.range(at: 1), in: raw), let status = Int(raw[statusRange]),
           let prefix = Range(match.range, in: raw) {
            let body = String(raw[prefix.upperBound...])
            let payload = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
            let code = (payload?["error"] as? String).flatMap { value -> String? in
                guard !value.isEmpty, value.count <= 120,
                      value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
                return value
            }
            var description = payload?["error_description"] as? String ?? payload?["message"] as? String ?? ""
            if let nested = (try? JSONSerialization.jsonObject(with: Data(description.utf8))) as? [String: Any] {
                description = [nested["title"], nested["description"]].compactMap { $0 as? String }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if description.isEmpty {
                description = payload == nil ? body : "PikPak could not complete this request\(code.map { " (\($0))" } ?? "")."
            }
            return .api(status: status, code: code, message: safeMessage(description))
        }
        let detail = raw.hasPrefix("error: ") ? String(raw.dropFirst(7)) : raw
        if detail.hasPrefix("invalid path: ") || detail.hasPrefix("not configured: ") || detail.hasPrefix("authentication failed: ") || PikPakSessionFailure.requiresSignIn(raw) {
            return .rejected(safeMessage(detail))
        }
        return .message(safeMessage(detail.isEmpty ? "PikPak could not complete the request." : detail))
    }
    static func safeMessage(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: #"(?i)Bearer\s+\S+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?"#,
            with: "[credential hidden]", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
    }
}


/// A bounded, read-only account request, independent of folder navigation.
/// Output is private and never includes a token in the app's visible log.
@MainActor
final class PikPakAccountVerifier {
    private var process: Process?
    private var deadline: Task<Void, Never>?
    private var timedOut = false
    var processIdentifier: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }

    func verify(engineURL: URL, environment: [String: String]) async throws -> PikPakAccountProfile {
        let data = try await request(engineURL: engineURL, environment: environment, arguments: ["account"])
        let profile = try JSONDecoder().decode(PikPakAccountProfile.self, from: data)
        guard !profile.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PikPakAccountError.invalidProfile }
        return profile
    }

    func quota(engineURL: URL, environment: [String: String]) async throws -> Data {
        try await request(engineURL: engineURL, environment: environment,
                          arguments: ["quota", "--json", "--with-transfer"])
    }

    func management(engineURL: URL, environment: [String: String], input: Data) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-management-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("request.json")
        try PikPakAccountStore.writePrivateFile(input, to: file)
        return try await request(engineURL: engineURL, environment: environment, arguments: ["manage", "--request-file", file.path])
    }

    func folderPage(engineURL: URL, environment: [String: String], parentID: String,
                    pageToken: String, shareRequestURL: URL?) async throws -> Data {
        let arguments: [String]
        if let shareRequestURL {
            arguments = ["share-browse", "--request-file", shareRequestURL.path]
        } else {
            arguments = ["browse", "--parent-id", parentID, "--limit", "500", "--page-token", pageToken]
        }
        return try await request(engineURL: engineURL, environment: environment, arguments: arguments)
    }

    private func request(engineURL: URL, environment: [String: String], arguments: [String]) async throws -> Data {
        try Task.checkCancellation()
        guard process == nil else { throw PikPakAccountError.unavailable }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-account-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("error")
        try PikPakAccountStore.writePrivateFile(Data(), to: outputURL)
        try PikPakAccountStore.writePrivateFile(Data(), to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let child = Process()
        child.executableURL = engineURL
        child.arguments = arguments
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = errors
        process = child
        timedOut = false
        defer { deadline?.cancel(); deadline = nil; process = nil }
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                child.terminationHandler = { completed in continuation.resume(returning: completed.terminationStatus) }
                do {
                    try child.run()
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                        self?.timedOut = true
                        self?.cancel()
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        guard !timedOut else { throw PikPakAccountError.unavailable }
        guard code == 0 else {
            let data = (try? PikPakAccountStore.readPrivateFile(errorURL)) ?? Data()
            let message = String(decoding: data, as: UTF8.self)
            if arguments.first == "manage" {
                throw PikPakManagementError.fromHelper(String(decoding: data, as: UTF8.self))
            }
            let rejected = PikPakSessionFailure.requiresSignIn(message)
            throw rejected ? PikPakAccountError.needsSignIn : PikPakAccountError.unavailable
        }
        return try PikPakAccountStore.readPrivateFile(outputURL)
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
