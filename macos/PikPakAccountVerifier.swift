import Foundation

/// A bounded, read-only account request, independent of folder navigation.
/// Output is private and never includes a token in the app's visible log.
@MainActor
final class PikPakAccountVerifier {
    private var process: Process?
    private var deadline: Task<Void, Never>?
    private var timedOut = false
    var processIdentifier: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }

    func verify(engineURL: URL, environment: [String: String]) async throws -> PikPakAccountProfile {
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
        child.arguments = ["account"]
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
            let message = String(decoding: data, as: UTF8.self).lowercased()
            let rejected = message.contains("invalid_grant") || message.contains("4126")
                || message.contains("401") || message.contains("unauthenticated")
                || (message.contains("refresh token") && (message.contains("expired") || message.contains("invalid") || message.contains("rejected")))
            throw rejected ? PikPakAccountError.needsSignIn : PikPakAccountError.unavailable
        }
        let profile = try JSONDecoder().decode(PikPakAccountProfile.self, from: PikPakAccountStore.readPrivateFile(outputURL))
        guard !profile.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PikPakAccountError.invalidProfile }
        return profile
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
