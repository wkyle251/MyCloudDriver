import Foundation

/// What one batch of downloads achieved. A batch can span several helper runs (automatic retries, files
/// added while it ran), so it accumulates until the whole queue has drained and is then reported once.
/// Only a batch that finished completely, with no failed file left, is ever reported.
struct DownloadBatch {
    var startedAt: Date
    var completedFiles = 0
    var skippedFiles = 0
    var savedBytes: UInt64 = 0
    var networkBytes: UInt64 = 0
    var destinations: [String] = []
    /// Transfers that failed during this batch. The batch is not finished while any of them is unresolved,
    /// and an earlier batch's failures never hold this one back.
    var failedIDs = Set<String>()

    mutating func note(destination: String) {
        if !destinations.contains(destination) { destinations.append(destination) }
    }
}

/// The text of the finished-downloads report that the status bar keeps until the next batch finishes.
enum DownloadReportText {
    static func summary(_ batch: DownloadBatch, finishedAt: Date) -> String {
        let elapsed = duration(finishedAt.timeIntervalSince(batch.startedAt))
        guard batch.completedFiles > 0 else { return "\(files(batch.skippedFiles)) already saved • \(elapsed)" }
        var parts = ["Downloaded \(files(batch.completedFiles))", bytes(batch.savedBytes), elapsed]
        if batch.skippedFiles > 0 { parts.append("\(batch.skippedFiles.formatted()) already saved") }
        return parts.joined(separator: " • ")
    }

    static func detail(_ batch: DownloadBatch, finishedAt: Date) -> String {
        let elapsedSeconds = max(0, finishedAt.timeIntervalSince(batch.startedAt))
        var lines = ["Finished \(finishedAt.formatted(date: .abbreviated, time: .shortened)) • took \(duration(elapsedSeconds))"]
        if let first = batch.destinations.first {
            lines.append("Saved to: " + first + (batch.destinations.count > 1 ? " (+\(batch.destinations.count - 1) more folders)" : ""))
        }
        if batch.completedFiles > 0 {
            var line = "Downloaded: \(files(batch.completedFiles)) (\(bytes(batch.savedBytes)))"
            if elapsedSeconds >= 1, batch.networkBytes > 0 {
                line += " • average \(bytes(UInt64(Double(batch.networkBytes) / elapsedSeconds)))/s"
            }
            lines.append(line)
        }
        if batch.skippedFiles > 0 { lines.append("Already saved: \(files(batch.skippedFiles))") }
        return lines.joined(separator: "\n")
    }

    static func files(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "file" : "files")" }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .binary)
    }

    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "0s" }
        let seconds = Int(min(interval.rounded(), 8_640_000))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
