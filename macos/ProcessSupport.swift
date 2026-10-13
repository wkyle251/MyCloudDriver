import AppKit
import Foundation

/// A small synchronized accumulator used by Process pipe callbacks. Keeping
/// structured JSON here means signed preview links never enter the UI log.
final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes: Int?

    init(maximumBytes: Int? = nil) { self.maximumBytes = maximumBytes }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        if let maximumBytes, data.count > maximumBytes {
            data.removeFirst(data.count - maximumBytes)
        }
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

/// Serializes pipe reads with EOF and schedules delivery while holding the
/// same lock. Completion is therefore queued after every live event; the GUI
/// needs no retained transcript or full replay to repair an exit-time race.
final class OrderedProcessLines: @unchecked Sendable {
    private let lock = NSLock()
    private let lines = ProcessLineBuffer()
    private var finished = false

    func read(_ handle: FileHandle, deliver: ([String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let data = handle.availableData
        let ready = lines.append(data)
        if !ready.isEmpty { deliver(ready) }
    }

    func finish(_ handle: FileHandle, deliver: ([String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let ready = lines.append(handle.readDataToEndOfFile()) + lines.drain()
        deliver(ready)
    }
}

/// Converts arbitrary pipe chunks into complete UTF-8 lines. Progress JSON can
/// be split across reads, so decoding each FileHandle callback independently
/// would occasionally lose an update.
final class ProcessLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        pending.append(data)
        let lines = extractCompleteLines()
        lock.unlock()
        return lines
    }

    func drain() -> [String] {
        lock.lock()
        let lines = extractCompleteLines()
        var result = lines
        if !pending.isEmpty {
            result.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        return result
    }

    private func extractCompleteLines() -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

struct CloudDownloadPromisePayload {
    let promisedName: String
    let remotePaths: [String]
    let wrapsSelectionInFolder: Bool
    let engineURL: URL
    let environment: [String: String]
    let jobs: Int
    let onStart: () -> Void
    let onFinish: (Result<Void, Error>) -> Void
}

/// Finder asks an NSItemProvider for its file representation only after the
/// user drops it. The coordinator materializes the selected cloud data in a
/// private temporary directory, then Finder copies that file or folder to the
/// exact drop location. This avoids exposing incomplete placeholder files.
final class CloudDownloadPromiseCoordinator {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.wky.PikPakDownloader.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func makeProvider(
        fileType: String,
        payload: CloudDownloadPromisePayload
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = payload.promisedName
        provider.registerFileRepresentation(
            forTypeIdentifier: fileType,
            fileOptions: [],
            visibility: .all
        ) { [weak self] completion in
            guard let self else {
                completion(
                    nil,
                    false,
                    NSError(
                        domain: "PikPakFilePromise",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The PikPak drag session expired."]
                    )
                )
                return nil
            }

            let progress = Progress(totalUnitCount: -1)
            let cancellation = FilePromiseCancellation()
            progress.cancellationHandler = { cancellation.cancel() }
            self.queue.addOperation {
                self.materialize(payload: payload, progress: progress, cancellation: cancellation, completion: completion)
            }
            return progress
        }
        return provider
    }

    private func materialize(
        payload: CloudDownloadPromisePayload,
        progress: Progress,
        cancellation: FilePromiseCancellation,
        completion: @escaping (URL?, Bool, Error?) -> Void
    ) {
        payload.onStart()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PikPakDownloader-Drag-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = payload.wrapsSelectionInFolder
            ? temporaryRoot.appendingPathComponent(payload.promisedName, isDirectory: true)
            : temporaryRoot

        do {
            defer { cancellation.finish() }
            if progress.isCancelled { cancellation.cancel() }
            try cancellation.check()
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let process = Process()
            let stderr = Pipe()
            let stderrBuffer = ProcessOutputBuffer()
            process.executableURL = payload.engineURL
            var arguments = ["download"]
            for path in payload.remotePaths {
                arguments.append(contentsOf: ["--path", path])
            }
            arguments.append(contentsOf: [
                "--output", outputDirectory.path,
                "--jobs", String(payload.jobs),
            ])
            process.arguments = arguments
            process.environment = payload.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderrBuffer.append(data)
                }
            }

            if progress.isCancelled { cancellation.cancel() }
            try cancellation.run(process)
            process.waitUntilExit()
            stderr.fileHandleForReading.readabilityHandler = nil
            let trailing = stderr.fileHandleForReading.readDataToEndOfFile()
            if !trailing.isEmpty {
                stderrBuffer.append(trailing)
            }

            try cancellation.check()
            guard process.terminationStatus == 0 else {
                let detail = FileSearchIndex.withoutStatusNotes(stderrBuffer.string())
                    .split(whereSeparator: \.isNewline)
                    .last
                    .map(String.init)
                    ?? "The PikPak download engine stopped."
                throw NSError(
                    domain: "PikPakFilePromise",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "PikPak could not complete the Finder download (exit \(process.terminationStatus)): \(detail)"
                    ]
                )
            }

            let resultURL: URL
            if payload.wrapsSelectionInFolder {
                resultURL = outputDirectory
            } else {
                let preferred = temporaryRoot.appendingPathComponent(payload.promisedName)
                if FileManager.default.fileExists(atPath: preferred.path) {
                    resultURL = preferred
                } else {
                    let children = try FileManager.default.contentsOfDirectory(
                        at: temporaryRoot,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    guard let downloaded = children.first else {
                        throw NSError(
                            domain: "PikPakFilePromise",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The downloader returned no local item."]
                        )
                    }
                    resultURL = downloaded
                }
            }

            payload.onFinish(.success(()))
            completion(resultURL, false, nil)
            Self.scheduleCleanup(of: temporaryRoot)
        } catch {
            payload.onFinish(.failure(error))
            completion(nil, false, error)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private static func scheduleCleanup(of directory: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3_600) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
