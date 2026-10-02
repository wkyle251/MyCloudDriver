import Foundation

@MainActor protocol TorrentRelayUploading: AnyObject {
    func run(request: [String: Any], directory: URL, context: PikPakManagementContext, event: @escaping ([String: Any]) -> Void) async throws
    func pause(_ paused: Bool) throws
    func stop()
}

/// Credentials are inherited through the existing account-specific private
/// session files. Neither tokens nor upload bodies are written to the journal.
@MainActor final class TorrentRelayUpload: TorrentRelayUploading {
    private var child: Process?
    private var control: URL?
    private var pending = Data()
    private var lastError = ""
    private var finished = false
    func pause(_ paused: Bool) throws {
        guard let control else { return }
        try LocalTorrentStore.write(JSONSerialization.data(withJSONObject: ["actions": paused ? ["*":"pause"] : [:]]), to: control)
    }
    func stop() { if child?.isRunning == true { child?.terminate() } }
    func run(request: [String: Any], directory: URL, context: PikPakManagementContext, event: @escaping ([String: Any]) -> Void) async throws {
        guard child == nil else { throw LocalTorrentError.message("This torrent upload is already running.") }
        try LocalTorrentStore.protect(directory)
        let input = directory.appendingPathComponent("relay-request.json")
        control = directory.appendingPathComponent("relay-control.json")
        try pause(false)
        try LocalTorrentStore.write(JSONSerialization.data(withJSONObject: request), to: input)
        let child = Process(), pipe = Pipe()
        child.executableURL = context.engineURL
        child.arguments = ["torrent-relay", "--request-file", input.path]
        var environment = context.environment
        environment["MYCLOUDDRIVER_TRANSFER_CONTROL"] = control!.path
        child.environment = environment; child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe
        pending = Data(); lastError = ""; finished = false
        self.child = child
        defer { self.child = nil; control = nil }
        try child.run()
        let reader = Task.detached(priority: .utility) { [weak self] in
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                await self?.consume(data, event: event)
            }
        }
        await withTaskCancellationHandler(operation: {
            await Task.detached(priority: .utility) { child.waitUntilExit() }.value
        }, onCancel: { if child.isRunning { child.terminate() } })
        await reader.value
        if !pending.isEmpty { consume(Data([10]), event: event) }
        guard !Task.isCancelled, child.terminationStatus == 0, finished else {
            throw LocalTorrentError.message(lastError.isEmpty ? "Upload interrupted. Saved cloud files will be checked before retrying." : PikPakManagementError.safeMessage(lastError))
        }
    }
    private func consume(_ data: Data, event: @escaping ([String: Any]) -> Void) {
        pending.append(data)
        if pending.count > 256 * 1024 { pending = Data(); lastError = "Upload output exceeded its limit."; stop(); return }
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            if line.hasPrefix("@torrent-relay:"), let data = line.dropFirst(15).data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if value["event"] as? String == "finished" { finished = true }
                event(value)
            } else if !line.isEmpty { lastError = String(line.suffix(2000)) }
        }
    }
}
