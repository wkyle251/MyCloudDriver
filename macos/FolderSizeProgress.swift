import Foundation

/// Metadata scan throughput, measured against monotonic elapsed time. A disk's
/// used space is only an estimate of the visible files' logical size.
struct FolderSizeProgress: Sendable {
    enum Phase: Sendable { case scanning, finalizing, complete }
    let files: Int
    let bytes: UInt64
    let usedDiskBytes: UInt64?
    let elapsedSeconds: TimeInterval
    var phase: Phase = .scanning
    var isComplete: Bool { phase == .complete }

    var fraction: Double? {
        guard let usedDiskBytes, usedDiskBytes > 0 else { return nil }
        return isComplete ? 1 : min(0.99, Double(bytes) / Double(usedDiskBytes))
    }

    private var hasRate: Bool { elapsedSeconds.isFinite && elapsedSeconds >= 0.5 && files > 0 }
    var bytesPerSecond: Double? { hasRate ? Double(bytes) / elapsedSeconds : nil }
    var filesPerSecond: Double? { hasRate ? Double(files) / elapsedSeconds : nil }
    var estimatedSecondsRemaining: TimeInterval? {
        if isComplete { return 0 }
        guard phase == .scanning else { return nil }
        guard let usedDiskBytes, usedDiskBytes > bytes, let rate = bytesPerSecond, rate > 0 else { return nil }
        let seconds = Double(usedDiskBytes - bytes) / rate
        return seconds.isFinite ? seconds : nil
    }

    var sizeSummary: String {
        let counted = Self.size(bytes)
        if isComplete { return counted }
        guard let usedDiskBytes, usedDiskBytes > 0 else { return "\(counted) so far" }
        return "\(counted) / ≈ \(Self.size(usedDiskBytes)) used"
    }

    var speedSummary: String {
        guard let bytesPerSecond, let filesPerSecond else { return "Scan speed: measuring…" }
        let rate = Self.size(SafeDisplayNumber.bytes(bytesPerSecond))
        return "Scan speed: \(rate)/s · \(filesPerSecond.formatted(.number.precision(.fractionLength(0...1)))) files/s"
    }

    var timeRemainingSummary: String {
        if isComplete { return "Scan complete" }
        if phase == .finalizing { return "Time left: finalizing folder totals…" }
        guard let usedDiskBytes, usedDiskBytes > 0 else { return "Time left: total size unknown" }
        if bytes >= usedDiskBytes { return "Time left: counting remaining files…" }
        guard let seconds = estimatedSecondsRemaining else { return "Time left: estimating…" }
        let duration = SafeDisplayNumber.integer(seconds, rounding: .up)
        let label = duration < 60 ? "\(duration)s" : duration < 3_600 ? "\(duration / 60)m \(duration % 60)s"
            : "\(duration / 3_600)h \((duration % 3_600) / 60)m"
        return "Time left: ≈ \(label)"
    }

    static let diskUsageHelp = "Progress and time are estimated from the disk’s used space. Hidden files, filesystem overhead and compression can make it differ from the scanned file sizes."
    static let speedHelp = "Average file size counted per second and files scanned per second. Folder sizes are read from metadata."

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
