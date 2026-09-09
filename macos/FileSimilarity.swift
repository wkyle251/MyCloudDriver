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
    var engineIndex: UInt64? = nil
    var engineId: String? = nil
    var state: String? = nil
    var scoreID: String { engineId ?? id }
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
    var scoreLabel: String { isExact ? "Identical content" : String(format: "Score %.1f%%", (minimumScore ?? 0) * 100) }
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
    var files: [SimilarityFile]? = nil
    var runId: String? = nil
    var resultRevision: UInt64? = nil
    var scoresRetained: UInt64? = nil
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
    let dataDir: String
    let modelDir: String
    let tempDir: String
    let reportPath: String
    let runtime: SimilarityRuntime
}

enum SimilarityScanStage: String, CaseIterable {
    case inventory, downloading, analysing, comparison, grouping, finishing
    var title: String {
        switch self {
        case .inventory: return "Finding files"
        case .downloading: return "Fetching cloud files"
        case .analysing: return "Analysing file content"
        case .comparison: return "Comparing files"
        case .grouping: return "Grouping matches"
        case .finishing: return "Preparing results"
        }
    }
    var stepTitle: String {
        switch self {
        case .inventory: return "Find files"
        case .downloading: return "Fetch copies"
        case .analysing: return "Analyse"
        case .comparison: return "Compare"
        case .grouping, .finishing: return "Results"
        }
    }
}

struct SimilarityScanProgress {
    var stage: SimilarityScanStage = .inventory
    var completed: UInt64 = 0
    var total: UInt64?
    var analysed: UInt64 = 0
    var skipped: UInt64 = 0
    var matches: UInt64 = 0
    var downloadedBytes: UInt64 = 0
    var currentName: String?
    var currentBytes: UInt64 = 0
    var currentSize: UInt64 = 0
    var operation = ""
    var bytesRead: UInt64 = 0
    var bytesHashed: UInt64 = 0
    var pairsCompared: UInt64 = 0
    var scoresRetained: UInt64 = 0

    init() {}
    init(event: [String: Any]) {
        let rawStage = event["stage"] as? String ?? ""
        stage = rawStage == "comparing" ? .comparison : SimilarityScanStage(rawValue: rawStage) ?? .analysing
        let counts = event["counts"] as? [String: Any] ?? [:]
        let completedKey = stage == .comparison ? "pairs_processed" : "files_processed"
        let totalKey = stage == .comparison ? "pairs_total" : "files_total"
        completed = (event["completed"] as? NSNumber)?.uint64Value ?? (counts[completedKey] as? NSNumber)?.uint64Value ?? 0
        total = (event["total"] as? NSNumber)?.uint64Value ?? ((stage == .analysing || stage == .comparison) ? (counts[totalKey] as? NSNumber)?.uint64Value : nil)
        analysed = (counts["files_ready"] as? NSNumber)?.uint64Value ?? 0
        skipped = ((counts["files_failed"] as? NSNumber)?.uint64Value ?? 0)
            + ((counts["files_excluded"] as? NSNumber)?.uint64Value ?? 0)
            + ((event["skipped"] as? NSNumber)?.uint64Value ?? 0)
        matches = ((counts["similar_pairs"] as? NSNumber)?.uint64Value ?? 0)
            + ((counts["exact_pairs"] as? NSNumber)?.uint64Value ?? 0)
        downloadedBytes = (event["downloaded_bytes"] as? NSNumber)?.uint64Value ?? 0
        let file = event["current_file"] as? [String: Any]
        currentName = file?["name"] as? String
        currentSize = (file?["bytes"] as? NSNumber)?.uint64Value ?? 0
        currentBytes = (event["file_bytes_read"] as? NSNumber)?.uint64Value ?? 0
        operation = event["operation"] as? String ?? ""
        bytesRead = (counts["bytes_read"] as? NSNumber)?.uint64Value ?? 0
        bytesHashed = (counts["bytes_hashed"] as? NSNumber)?.uint64Value ?? 0
        pairsCompared = (counts["pairs_compared"] as? NSNumber)?.uint64Value ?? 0
        scoresRetained = (counts["scores_retained"] as? NSNumber)?.uint64Value ?? 0
    }
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    var percentLabel: String? {
        fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
    }
    var completedLabel: String {
        let count = total.map { "\(completed.formatted()) of \($0.formatted())" } ?? completed.formatted()
        switch stage {
        case .inventory: return "\(count) files found"
        case .downloading: return "\(count) files processed"
        case .analysing: return "\(count) items processed"
        case .comparison: return "\(count) pairs checked"
        case .grouping: return "\(count) match entries grouped"
        case .finishing: return "Saving the report and clearing temporary files"
        }
    }
    var currentOperation: String {
        switch operation {
        case "downloading": return "Downloading temporary copy"
        case "decoding": return "Decoding and analysing content"
        case "hashing": return "Checking identical content"
        default: return "Reading file content"
        }
    }
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    var currentByteLabel: String {
        guard currentSize > 0 else { return Self.bytes(currentBytes) }
        return "\(Self.bytes(min(currentBytes, currentSize))) of \(Self.bytes(currentSize))"
    }
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
    @Published private(set) var isRunning = false { didSet { if oldValue != isRunning { onRunningChanged() } } }
    @Published private(set) var isCancelling = false
    @Published private(set) var message = "Ready to scan"
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var progress = SimilarityScanProgress()
    @Published private(set) var startedAt: Date?
    var externalTitle: String?
    var externalDuplicatesOnly = false
    var externalScopeNames: [String] = []
    var prepareExternalScope: (() async throws -> [URL])?
    var cleanupExternalScope: () -> Void = {}
    var transformExternalReport: ((SimilarityReport) -> SimilarityReport)?
    private var preparationTask: Task<Void, Never>?
    @Published private(set) var report: SimilarityReport?
    @Published var error: String?
    private var process: Process?
    private var generation = UUID()
    private var scopes: [URL] = []
    var onRunningChanged: () -> Void = {}
    let results = SimilarityResultsModel()
    private(set) var resultConfiguration: SimilarityConfiguration?

    init(source: SimilaritySource, activity: FinderTaskActivityStore) { self.source = source; self.activity = activity }
    var processIdentifier: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    var scopeLabel: String {
        let names = externalTitle != nil ? externalScopeNames : source == .local ? localURLs.map(\.lastPathComponent) : cloudRoots.map { $0.path == "/" ? "All PikPak files" : $0.path }
        return names.isEmpty ? "No scope selected" : names.count == 1 ? names[0] : "\(names.count) selected locations"
    }
    var canStart: Bool {
        !isRunning && (externalDuplicatesOnly || !families.isEmpty) && (externalTitle != nil ? !externalScopeNames.isEmpty : source == .local ? !localURLs.isEmpty : !cloudRoots.isEmpty)
            && threshold.isFinite && (0.05...1).contains(threshold)
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
        resultConfiguration = configuration; results.reset()
        guard let prepareExternalScope else { launch(configuration); return }
        isRunning = true; isCancelling = false; report = nil; error = nil; startedAt = Date()
        message = "Preparing \(externalTitle ?? "drive") files…"; detail = scopeLabel
        progress = SimilarityScanProgress(event: ["stage":"downloading"])
        activity.begin(source.taskKind, scope: scopeLabel, message: message)
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await prepareExternalScope()
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw CloudDriveError.message("No readable files were found in this scope.") }
                self.localURLs = urls
                if self.externalDuplicatesOnly {
                    let report = try await NativeDriveDuplicates.scan(urls) { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.isRunning, !self.isCancelling else { return }; self.receive(event)
                        }
                    }
                    self.preparationTask = nil; self.finish(report, diagnostic: "", exitCode: 0)
                } else { self.preparationTask = nil; self.launch(configuration) }
            } catch {
                self.isCancelling = self.isCancelling || error is CancellationError
                self.preparationTask = nil
                self.finish(nil, diagnostic: error.localizedDescription, exitCode: 1)
            }
        }
    }

    func externalProgress(_ value: CloudDriveProgress) {
        guard isRunning, !isCancelling else { return }
        var event: [String: Any] = ["event":"progress", "stage":value.total > 0 ? "downloading" : "inventory", "completed":value.completed,
            "current_file":["name":value.message, "bytes":value.fileSize], "file_bytes_read":value.bytes, "operation":"downloading"]
        if value.total > 0 { event["total"] = value.total }
        receive(event, preparing: true)
    }

    private func launch(_ configuration: SimilarityConfiguration) {
        let runID = UUID()
        let directory = configuration.temporaryDirectory.appendingPathComponent(runID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.temporaryDirectory.path)
            let reportURL = directory.appendingPathComponent("report.json")
            let request = SimilarityRequest(source: source, localPaths: source == .local ? localURLs.map(\.path) : [],
                cloudItems: source == .cloud ? cloudRoots : [], families: families.sorted(), threshold: threshold,
                exactDuplicates: exactDuplicates, includeHidden: includeHidden,
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
            progress = externalTitle == nil ? SimilarityScanProgress() : SimilarityScanProgress(event: ["stage":"analysing"])
            if externalTitle == nil || startedAt == nil { startedAt = Date() }
            message = "Starting \(externalTitle ?? source.title) scan…"; detail = ""
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

    private func receive(_ event: [String: Any], preparing: Bool = false) {
        guard event["event"] as? String == "progress" else { return }
        var event = event
        if externalTitle != nil && !preparing && event["stage"] as? String == "inventory" { event["stage"] = "analysing" }
        progress = SimilarityScanProgress(event: event)
        message = progress.stage.title + "…"
        fraction = progress.fraction
        detail = progress.completedLabel
        if let name = progress.currentName { detail += " · \(name)" }
        if progress.downloadedBytes > 0 { detail += " · \(SimilarityScanProgress.bytes(progress.downloadedBytes)) fetched" }
        activity.update(source.taskKind, message: message, detail: detail, fraction: fraction)
    }

    private func finish(_ result: SimilarityReport?, diagnostic: String, exitCode: Int32) {
        let cancelled = isCancelling || result?.status == "cancelled"
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes = []
        process = nil; isRunning = false; isCancelling = false; fraction = nil
        report = result.map { transformExternalReport?($0) ?? $0 }
        if let report { results.load(report, configuration: resultConfiguration) }
        cleanupExternalScope()
        if let result = report, exitCode == 0 {
            let state: FinderTaskActivity.State = cancelled ? .cancelled : result.status == "failed" ? .failed : result.status == "partial" ? .partial : .completed
            message = cancelled ? "Scan cancelled" : state == .failed ? "Scan could not finish" : "\(result.analysedFiles.formatted()) files ready to review"
            detail = "\(result.analysedFiles.formatted()) analysed · \(result.skippedFiles.formatted()) skipped"
            activity.finish(source.taskKind, state: state, message: "\(source.title): \(message)", detail: detail)
        } else {
            message = cancelled ? "Scan cancelled" : "Scan could not finish"
            if !cancelled { error = diagnostic.isEmpty ? "The scan engine could not finish (exit \(exitCode)). Try a smaller scope or check the selected files." : FileSearchIndex.redacted(diagnostic) }
            activity.finish(source.taskKind, state: cancelled ? .cancelled : .failed, message: message, detail: error)
        }
    }

    func cancel() {
        if let preparationTask {
            isCancelling = true; message = "Stopping scan…"
            activity.stopping(source.taskKind, message: message)
            preparationTask.cancel(); return
        }
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
        results.reset(); resultConfiguration = nil
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
    func setFixtureReport(_ value: SimilarityReport) { report = value; results.load(value, configuration: resultConfiguration); message = "\(value.analysedFiles) files ready to review" }
    func setFixtureProgress(_ event: [String: Any]) {
        report = nil; isRunning = true; startedAt = Date().addingTimeInterval(-72)
        activity.begin(source.taskKind, scope: scopeLabel, message: "Starting scan")
        receive(event)
    }
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
    var externalTitle: String?
    var externalSymbol = "externaldrive"
    @Published var duplicatesOnly = false
    var openExternalFile: ((SimilarityFile) -> Void)?
    var preparePreview: ((SimilarityFile, URL) async throws -> URL)?
    let preview = SimilarityPreviewModel()
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
        window?.title = duplicatesOnly ? "Check for Duplicates" : "Find Similar Files"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func close() { runs.forEach { $0.cancel(); $0.results.reset() }; preview.close(); window?.close(); window?.contentView = nil; window = nil }
}
