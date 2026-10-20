import Foundation

/// Presentation only: retained bytes stay owned by the source's shared RAM cache.
struct MediaPreviewTransferState: Equatable {
    var bytesPerSecond: Double?
    /// Nil falls back to AVPlayer's ranges; an empty array means nothing is retained yet.
    var ranges: [ClosedRange<Double>]?
    var preparing = false
    var complete = false
    var waitingForMemory = false

    var speedText: String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        let bytes = SafeDisplayNumber.bytes(bytesPerSecond)
        let amount = bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        return "\(amount)/s"
    }

    static func ranges(fraction: Double?) -> [ClosedRange<Double>] {
        guard let fraction, fraction.isFinite, fraction > 0 else { return [] }
        return [0...min(1, fraction)]
    }
}
