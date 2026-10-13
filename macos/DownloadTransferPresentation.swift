import Foundation

enum DownloadTransferPresentation {
    /// `finalFailure` is false for a failed file that is still retrying: it is never labelled "Failed" until a
    /// permanent cause is confirmed.
    static func title(_ state: DownloadTransferState, cancelled: Bool, paused: Bool, automaticRetry: String? = nil,
                      finalFailure: Bool = true) -> String {
        switch state {
        case .completed: return "Complete"
        case .skipped: return "Already saved"
        case .failed, .stopped:
            if cancelled { return "Cancelled" }
            if paused { return "Paused" }
            if let automaticRetry {
                return automaticRetry == "Retry queued" ? "Retry queued" : "Waiting to retry"
            }
            if state == .failed { return finalFailure ? "Failed" : "Waiting to retry" }
            return "Stopped"
        default:
            if cancelled { return "Cancelled" }
            if paused { return "Paused" }
            switch state {
            case .queued: return "Waiting"
            case .preparing: return "Preparing"
            case .downloading: return "Downloading"
            case .retrying: return "Waiting to retry"
            default: return ""
            }
        }
    }
}
