import Foundation

enum SimilarityNetworkFailure {
    static func isTemporary(_ error: Error, depth: Int = 0) -> Bool {
        let value=error as NSError
        if value.domain == NSURLErrorDomain && [NSURLErrorTimedOut,NSURLErrorCannotFindHost,NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,NSURLErrorDNSLookupFailed,NSURLErrorNotConnectedToInternet,
            NSURLErrorResourceUnavailable,NSURLErrorDataNotAllowed].contains(value.code) { return true }
        if depth < 3, let underlying=value.userInfo[NSUnderlyingErrorKey] as? Error { return isTemporary(underlying,depth:depth+1) }
        return false
    }
}

struct SimilarityNativeScope: Codable {
    let drive: CloudDriveKind
    let providerRoot: CloudDriveLocation
    let location: CloudDriveLocation
    let selection: [CloudDriveItem]
    var bookmark: Data?
    // Missing in older sessions, which always analysed originals.
    var photosUsePreviews: Bool? = nil
}

struct SimilaritySavedSession: Codable, Identifiable {
    let id: String
    let source: SimilaritySource
    var localURLs: [URL]
    var cloudRoots: [SimilarityCloudRoot]
    var nativeScope: SimilarityNativeScope?
    var scope: String
    var families: Set<String>
    var threshold: Double
    var exactDuplicates: Bool
    var resources: SimilarityResourceLimits
    var state: String
    var startedAt: Date
    var updatedAt: Date
    var activeElapsedSeconds: Double? = nil
    // Isolate snapshot decoding from the recovery descriptor. A newer or
    // damaged progress payload must never make the Resume entry disappear.
    var progressSnapshot: Data? = nil
    var progress: SimilarityScanProgress? {
        get { progressSnapshot.flatMap { try? JSONDecoder().decode(SimilarityScanProgress.self, from: $0) } }
        set {
            guard var value = newValue else { progressSnapshot = nil; return }
            value.downloads = Array(value.downloads.prefix(128))
            value.currentName = value.currentName.map { String($0.prefix(4096)) }
            var bytes = try? JSONEncoder().encode(value)
            if (bytes?.count ?? 0) > 2 * 1_024 * 1_024 {
                value.downloads = []; bytes = try? JSONEncoder().encode(value)
            }
            progressSnapshot = bytes
        }
    }

    var elapsedSeconds: Double {
        // Older descriptors did not separate paused time. Preserve their last
        // known duration, without counting time since the app was closed.
        let seconds = activeElapsedSeconds ?? updatedAt.timeIntervalSince(startedAt)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}

struct SimilarityScanClock {
    private var accumulated: TimeInterval
    private var runningSince: Date?
    var isRunning: Bool { runningSince != nil }

    init(elapsedSeconds: TimeInterval = 0) {
        accumulated = elapsedSeconds.isFinite ? max(0, elapsedSeconds) : 0
    }
    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
    mutating func resume(at date: Date) {
        if runningSince == nil { runningSince = date }
    }
    mutating func pause(at date: Date) {
        accumulated = elapsed(at: date); runningSince = nil
    }
}

extension SimilarityScanProgress {
    func afterHelperRestart() -> Self {
        var next = self
        next.activeFiles = 0; next.fetchingFiles = 0; next.readingFiles = 0; next.encodingFiles = 0
        next.acceleratorActive = 0; next.waitingAcceleratorFiles = 0; next.waitingProcessingFiles = 0
        next.waitingMemoryFiles = 0; next.waitingReuseFiles = 0; next.waitingDownloadFiles = 0
        next.retryingDownloadFiles = 0; next.readyFiles = 0; next.resolvingFiles = 0
        next.originalMemoryBytes = 0; next.analysisMemoryBytes = 0; next.retainedDownloadMinimum = 0
        next.downloads = []; next.downloadCount = 0; next.omittedDownloads = 0
        next.downloadSpeed = 0; next.downloadForecastBytes = 0; next.hasDownloadTelemetry = false
        next.currentName = nil; next.currentBytes = 0; next.currentSize = 0
        return next
    }
    mutating func restoreSummary(from saved: Self) {
        completed = saved.completed; total = saved.total; analysed = saved.analysed
        skipped = saved.skipped; matches = saved.matches; unsupportedFiles = saved.unsupportedFiles
        failedFiles = saved.failedFiles; scoresRetained = saved.scoresRetained; pairsCompared = saved.pairsCompared
        vectorsEncoded = saved.vectorsEncoded; cacheHits = saved.cacheHits
        foundFiles = max(foundFiles, saved.foundFiles)
        cloudBytesReady = saved.cloudBytesReady; cloudBytesTotal = saved.cloudBytesTotal
        cloudByteInventoryComplete = saved.cloudByteInventoryComplete
    }
    static func cumulative(_ base: UInt64, _ current: UInt64) -> UInt64 {
        let sum = base.addingReportingOverflow(current)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}

/// Descriptors contain scope, settings and progress. Credentials are obtained afresh
/// from the connected account when Resume is pressed.
@MainActor
enum SimilaritySessionStore {
    private static var claimed: Set<URL> = []
    static func directory(_ configuration: SimilarityConfiguration, id: String) -> URL {
        configuration.dataDirectory.appendingPathComponent("checkpoints", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    static func sameAccount(_ first: SimilarityConfiguration, _ second: SimilarityConfiguration) -> Bool {
        first.dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path == second.dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func claim(_ configuration: SimilarityConfiguration, id: String) { claimed.insert(directory(configuration,id:id)) }
    static func isClaimed(_ configuration: SimilarityConfiguration, id: String) -> Bool { claimed.contains(directory(configuration,id:id)) }
    static func release(_ configuration: SimilarityConfiguration, id: String) { claimed.remove(directory(configuration,id:id)) }
    static func save(_ value: SimilaritySavedSession, configuration: SimilarityConfiguration) throws {
        guard UUID(uuidString:value.id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let root=directory(configuration,id:value.id)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=root.appendingPathComponent("session.json")
        try JSONEncoder().encode(value).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func pause(_ value: SimilaritySavedSession, configuration: SimilarityConfiguration) throws {
        try save(value,configuration:configuration)
        let file=directory(configuration,id:value.id).appendingPathComponent("pause")
        try Data().write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func updateLiveResources(_ resources: SimilarityResourceLimits, configuration: SimilarityConfiguration, id: String) throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let file = directory(configuration, id: id).appendingPathComponent("live-resources.json")
        try encoder.encode(resources).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func removePause(_ configuration: SimilarityConfiguration, id: String) throws {
        let url=directory(configuration,id:id).appendingPathComponent("pause")
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
    static func discard(_ configuration: SimilarityConfiguration, id: String, report: SimilarityReport? = nil) {
        guard UUID(uuidString:id) != nil else { return }
        let root=directory(configuration,id:id)
        if let report=report ?? loadReport(configuration,id:id), let run=report.runId,
           run.hasPrefix("mcd2-"), run.count == 37, run.dropFirst(5).allSatisfy({ $0.isHexDigit }) {
            try? FileManager.default.removeItem(at:configuration.dataDirectory.appendingPathComponent("runs").appendingPathComponent(run+".sqlite3"))
        }
        release(configuration,id:id)
        // Called only after the owning helper has stopped.
        try? FileManager.default.removeItem(at:root)
    }
    static func saveReport(_ report: SimilarityReport, configuration: SimilarityConfiguration, id: String) throws {
        let path=directory(configuration,id:id).appendingPathComponent("report.json")
        try JSONEncoder().encode(report).write(to:path,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
    }
    static func loadReport(_ configuration: SimilarityConfiguration, id: String) -> SimilarityReport? {
        let path=directory(configuration,id:id).appendingPathComponent("report.json")
        guard (try? path.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data=try? Data(contentsOf:path), data.count <= 256 * 1_024 * 1_024 else { return nil }
        return try? JSONDecoder().decode(SimilarityReport.self,from:data)
    }
    static func available(_ configuration: SimilarityConfiguration, source: SimilaritySource) -> [SimilaritySavedSession] {
        let root=configuration.dataDirectory.appendingPathComponent("checkpoints",isDirectory:true)
        let children=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey],options:.skipsHiddenFiles)) ?? []
        return children.compactMap { directory in
            guard !claimed.contains(directory.standardizedFileURL.resolvingSymlinksInPath()), UUID(uuidString:directory.lastPathComponent) != nil,
                  (try? directory.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let bytes=try? Data(contentsOf:directory.appendingPathComponent("session.json")), bytes.count <= 4 * 1_024 * 1_024,
                  let value=try? JSONDecoder().decode(SimilaritySavedSession.self,from:bytes),
                  value.id == directory.lastPathComponent, value.source == source,
                  ["running","paused","interrupted","cancelled","completed","partial","failed"].contains(value.state) else { return nil }
            return value
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
