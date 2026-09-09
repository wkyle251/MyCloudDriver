import AppKit
import Combine
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum SimilaritySource: String, Codable, CaseIterable, Identifiable {
    case cloud, local
    var id: Self { self }
    var title: String { self == .cloud ? "PikPak Cloud" : "This Mac" }
    var symbol: String { self == .cloud ? "cloud" : "laptopcomputer" }
    var taskKind: FinderTaskKind { self == .cloud ? .similarityCloud : .similarityLocal }
}

struct SimilarityAncestor: Codable { let id: String; let name: String }
struct SimilarityCloudRoot: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    let size: UInt64
    let ancestors: [SimilarityAncestor]
}
struct SimilarityFile: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let bytes: UInt64
    let family: String
    let localPath: String?
    let cloudId: String?
    let ancestors: [SimilarityAncestor]
    var symbol: String {
        switch family { case "image": return "photo"; case "audio": return "waveform"; case "video": return "film"; default: return "doc.text" }
    }
}
struct SimilarityGroup: Codable, Identifiable {
    let id: String
    let matchKind: String
    let family: String
    let minimumScore: Double?
    let memberCount: UInt64
    let members: [SimilarityFile]
    var isExact: Bool { matchKind == "byte_identical" }
    var title: String { members.first?.name ?? "Match group" }
    var scoreLabel: String { isExact ? "Identical content" : String(format: "Score %.3f", minimumScore ?? 0) }
}
struct SimilarityIssue: Codable { let path: String; let reason: String }
struct SimilarityReport: Codable {
    let source: SimilaritySource
    let scope: [String]
    let status: String
    let threshold: Double
    let scannedFiles: UInt64
    let analysedFiles: UInt64
    let skippedFiles: UInt64
    let downloadedBytes: UInt64
    let totalGroups: UInt64
    let groups: [SimilarityGroup]
    let issues: [SimilarityIssue]
    let truncated: Bool
    let coverage: String
    let elapsedSeconds: Double
}

struct SimilarityConfiguration {
    let executable: URL
    let models: URL
    let worker: URL
    let dataDirectory: URL
    let temporaryDirectory: URL
    let environment: [String: String]
}

private struct SimilarityRuntime: Encodable {
    let workerPath: String
    let ffmpegPath: String?
    let ffprobePath: String?
    let onnxruntimePath: String
    let pdfiumPath: String
}
private struct SimilarityRequest: Encodable {
    let source: SimilaritySource
    let localPaths: [String]
    let cloudItems: [SimilarityCloudRoot]
    let families: [String]
    let threshold: Double
    let exactDuplicates: Bool
    let includeHidden: Bool
    let maxFileBytes: UInt64
    let downloadBudgetBytes: UInt64
    let dataDir: String
    let modelDir: String
    let tempDir: String
    let reportPath: String
    let runtime: SimilarityRuntime
}

/// Each source owns its process and published state. Progress never causes
/// DownloaderModel to invalidate the Browser's potentially large outline.
@MainActor
final class SimilarityScanModel: ObservableObject {
    let source: SimilaritySource
    let activity: FinderTaskActivityStore
    @Published var localURLs: [URL] = []
    @Published var cloudRoots: [SimilarityCloudRoot] = []
    @Published var families: Set<String> = SimilarityScanModel.visualSimilarityAvailable
        ? ["text", "image", "audio", "video"] : ["text", "audio"]
    @Published var threshold = 0.9
    @Published var exactDuplicates = true
    @Published var includeHidden = false
    @Published var maxFileMB = "1024"
    @Published var downloadGB = "10"
    @Published private(set) var isRunning = false { didSet { if oldValue != isRunning { onRunningChanged() } } }
    @Published private(set) var isCancelling = false
    @Published private(set) var message = "Ready to scan"
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var report: SimilarityReport?
    @Published var error: String?
    private var process: Process?
    private var generation = UUID()
    private var scopes: [URL] = []
    var onRunningChanged: () -> Void = {}

    init(source: SimilaritySource, activity: FinderTaskActivityStore) { self.source = source; self.activity = activity }
    var processIdentifier: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    var scopeLabel: String {
        let names = source == .local ? localURLs.map(\.lastPathComponent) : cloudRoots.map { $0.path == "/" ? "All PikPak files" : $0.path }
        return names.isEmpty ? "No scope selected" : names.count == 1 ? names[0] : "\(names.count) selected locations"
    }
    var canStart: Bool {
        !isRunning && !families.isEmpty && (source == .local ? !localURLs.isEmpty : !cloudRoots.isEmpty)
            && Self.integer(maxFileMB, maximum: 102_400) != nil && Self.integer(downloadGB, maximum: 1000) != nil
    }
    static func numericInput(_ text: String) -> String { String(text.filter { $0 >= "0" && $0 <= "9" }.prefix(6)) }
    static func integer(_ text: String, maximum: UInt64) -> UInt64? {
        guard !text.isEmpty, text == numericInput(text), let value = UInt64(text), (1...maximum).contains(value) else { return nil }
        return value
    }
    static func mediaTool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var visualSimilarityAvailable: Bool {
        // The pinned ONNX Runtime dylib has LC_BUILD_VERSION minos 14.0.
        // Keep the rest of the app and text/audio scans usable on macOS 13.
        if #available(macOS 14, *) { return true }
        return false
    }

    func chooseLocalFiles() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose files or folders to compare"
        panel.prompt = "Add to Scan"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self, !self.isRunning else { return }
                let existing = Set(self.localURLs.map(\.standardizedFileURL))
                self.localURLs.append(contentsOf: panel.urls.filter { !existing.contains($0.standardizedFileURL) })
                self.error = nil
            }
        }
    }

    func start(_ configuration: SimilarityConfiguration) {
        guard canStart else { return }
        let runID = UUID()
        let directory = configuration.temporaryDirectory.appendingPathComponent(runID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.temporaryDirectory.path)
            let reportURL = directory.appendingPathComponent("report.json")
            let request = SimilarityRequest(source: source, localPaths: source == .local ? localURLs.map(\.path) : [],
                cloudItems: source == .cloud ? cloudRoots : [], families: families.sorted(), threshold: threshold,
                exactDuplicates: exactDuplicates, includeHidden: includeHidden,
                maxFileBytes: Self.integer(maxFileMB, maximum: 102_400)! * 1024 * 1024,
                downloadBudgetBytes: Self.integer(downloadGB, maximum: 1000)! * 1024 * 1024 * 1024,
                dataDir: configuration.dataDirectory.path, modelDir: configuration.models.path,
                tempDir: directory.appendingPathComponent("copies", isDirectory: true).path,
                reportPath: reportURL.path,
                runtime: SimilarityRuntime(workerPath: configuration.worker.path, ffmpegPath: Self.mediaTool("ffmpeg"),
                    ffprobePath: Self.mediaTool("ffprobe"), onnxruntimePath: configuration.models.appendingPathComponent("runtime/libonnxruntime.dylib").path,
                    pdfiumPath: configuration.models.appendingPathComponent("runtime/libpdfium.dylib").path))
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            let requestURL = directory.appendingPathComponent("request.json")
            try encoder.encode(request).write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            let child = Process(); let output = Pipe(); let errors = Pipe()
            child.executableURL = configuration.executable
            child.currentDirectoryURL = directory
            child.arguments = ["similarity-scan", "--request-file", requestURL.path]
            child.environment = configuration.environment
            child.standardOutput = output; child.standardError = errors; child.standardInput = FileHandle.nullDevice
            generation = runID; process = child
            scopes = localURLs.filter { $0.startAccessingSecurityScopedResource() }
            isRunning = true; isCancelling = false; report = nil; error = nil; fraction = nil
            message = "Starting \(source.title) scan…"; detail = ""
            activity.begin(source.taskKind, scope: scopeLabel, message: message)
            let reader = SimilarityProcessReader()
            reader.start(output: output, errors: errors) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == runID, self.isRunning, !self.isCancelling else { return }
                    self.receive(event)
                }
            }
            child.terminationHandler = { [weak self] child in
                // Wait for both pipes and decode the report away from the GUI.
                reader.finish(reportURL: reportURL) { report, diagnostic in
                    try? FileManager.default.removeItem(at: directory)
                    Task { @MainActor in
                        guard let self, self.generation == runID else { return }
                        self.finish(report, diagnostic: diagnostic, exitCode: child.terminationStatus)
                    }
                }
            }
            do { try child.run() }
            catch {
                child.terminationHandler = nil
                try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
                throw error
            }
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            finish(nil, diagnostic: error.localizedDescription, exitCode: 1)
        }
    }

    private func receive(_ event: [String: Any]) {
        guard event["event"] as? String == "progress" else { return }
        let stage = event["stage"] as? String ?? "analysing"
        switch stage {
        case "downloading":
            let complete = (event["completed"] as? NSNumber)?.doubleValue ?? 0
            let total = (event["total"] as? NSNumber)?.doubleValue ?? 0
            message = "Fetching temporary copies · \(Int(complete)) of \(Int(total))"
            fraction = total > 0 ? complete / total : nil
            detail = event["name"] as? String ?? ""
        case "discovery":
            if let counts = event["counts"] as? [String: Any] {
                message = "Analysing file content…"; detail = countsDetail(counts)
            } else {
                message = "Finding cloud files…"
                detail = "\((event["discovered"] as? NSNumber)?.intValue ?? 0) files found"
            }
            fraction = nil
        default:
            message = stage == "grouping" ? "Grouping matching files…"
                : stage == "matching" || stage == "comparison" ? "Comparing file content…" : "Analysing file content…"
            detail = (event["counts"] as? [String: Any]).map(countsDetail) ?? ""
            fraction = nil
        }
        if let bytes = (event["downloaded_bytes"] as? NSNumber)?.int64Value, bytes > 0 {
            detail += " · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) fetched"
        }
        activity.update(source.taskKind, message: message, detail: detail, fraction: fraction)
    }

    private func countsDetail(_ counts: [String: Any]) -> String {
        let found = (counts["files_discovered"] as? NSNumber)?.intValue ?? 0
        let ready = (counts["files_ready"] as? NSNumber)?.intValue ?? 0
        let pairs = (counts["pairs_compared"] as? NSNumber)?.intValue ?? 0
        return "\(found.formatted()) files · \(ready.formatted()) analysed · \(pairs.formatted()) pairs compared"
    }

    private func finish(_ result: SimilarityReport?, diagnostic: String, exitCode: Int32) {
        let cancelled = isCancelling || result?.status == "cancelled"
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes = []
        process = nil; isRunning = false; isCancelling = false; fraction = nil
        report = result
        if let result, exitCode == 0 {
            let state: FinderTaskActivity.State = cancelled ? .cancelled : result.status == "failed" ? .failed : result.status == "partial" ? .partial : .completed
            message = cancelled ? "Scan cancelled" : state == .failed ? "Scan could not finish" : "\(result.totalGroups.formatted()) match groups found"
            detail = "\(result.analysedFiles.formatted()) analysed · \(result.skippedFiles.formatted()) skipped"
            activity.finish(source.taskKind, state: state, message: "\(source.title): \(message)", detail: detail)
        } else {
            message = cancelled ? "Scan cancelled" : "Scan could not finish"
            if !cancelled { error = diagnostic.isEmpty ? "The scan engine could not finish (exit \(exitCode)). Try a smaller scope or check the selected files." : FileSearchIndex.redacted(diagnostic) }
            activity.finish(source.taskKind, state: cancelled ? .cancelled : .failed, message: message, detail: error)
        }
    }

    func cancel() {
        guard let child = process, child.isRunning, !isCancelling else { return }
        isCancelling = true; message = "Stopping and removing temporary copies…"
        activity.stopping(source.taskKind, message: message)
        child.terminate()
        // A crashed decoder must not keep the operation active indefinitely.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func clearAccount() {
        guard !isRunning else { return }
        cloudRoots = []; report = nil; error = nil; message = "Ready to scan"; detail = ""
    }

    func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Similarity-\(source.rawValue).json"
        panel.title = "Export similarity results"; panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    try encoder.encode(report).write(to: url, options: .atomic)
                } catch { Task { @MainActor in self?.error = error.localizedDescription } }
            }
        }
    }

    #if FINDER_WORKSPACE_TESTS
    func setFixtureReport(_ value: SimilarityReport) { report = value; message = "\(value.totalGroups) match groups found" }
    #endif
}

/// Pipe decoding is bounded and performed off the main queue, including the
/// final potentially large result. stdout never carries original file content.
private final class SimilarityProcessReader {
    private let group = DispatchGroup()
    private var diagnostic = Data()
    func start(output: Pipe, errors: Pipe, receive: @escaping ([String: Any]) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave(); try? output.fileHandleForReading.close() }
            var buffer = Data()
            while let chunk = try? output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                    if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { receive(event) }
                }
                if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: false) }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave(); try? errors.fileHandleForReading.close() }
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                if diagnostic.count < 16_384 { diagnostic.append(chunk.prefix(16_384 - diagnostic.count)) }
            }
        }
    }
    func finish(reportURL: URL, completion: @escaping (SimilarityReport?, String) -> Void) {
        group.notify(queue: .global(qos: .utility)) { [self] in
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            var report: SimilarityReport?
            var message = String(data: diagnostic, encoding: .utf8) ?? ""
            do {
                let size = try reportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size < 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                report = try decoder.decode(SimilarityReport.self, from: Data(contentsOf: reportURL))
            } catch { if message.isEmpty { message = "The scan did not produce a readable report. \(error.localizedDescription)" } }
            completion(report, message)
        }
    }
}

@MainActor
final class FileSimilarityCoordinator: ObservableObject {
    let cloud: SimilarityScanModel
    let local: SimilarityScanModel
    @Published var source: SimilaritySource = .cloud
    var configuration: (SimilaritySource) throws -> SimilarityConfiguration = { _ in throw CocoaError(.fileNoSuchFile) }
    var cloudScope: (Bool) throws -> [SimilarityCloudRoot] = { _ in [] }
    var openCloudFile: (SimilarityFile) -> Void = { _ in }
    private var window: NSWindow?
    var runs: [SimilarityScanModel] { [cloud, local] }

    init(activity: FinderTaskActivityStore) {
        cloud = SimilarityScanModel(source: .cloud, activity: activity)
        local = SimilarityScanModel(source: .local, activity: activity)
    }
    func useBrowserSelection(_ selection: Bool) {
        guard !cloud.isRunning else { return }
        do { cloud.cloudRoots = try cloudScope(selection); cloud.error = nil }
        catch { cloud.error = error.localizedDescription }
    }
    func start(_ model: SimilarityScanModel) {
        do { model.start(try configuration(model.source)) }
        catch { model.error = error.localizedDescription }
    }
    func present(source requested: SimilaritySource? = nil) {
        if let requested { source = requested }
        if cloud.cloudRoots.isEmpty && !cloud.isRunning { useBrowserSelection(false) }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Find Similar Files"
            window.minSize = NSSize(width: 900, height: 710)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FileSimilarityView(coordinator: self))
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func close() { runs.forEach { $0.cancel() }; window?.close(); window?.contentView = nil; window = nil }
}
