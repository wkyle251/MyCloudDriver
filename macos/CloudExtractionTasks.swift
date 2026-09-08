import Foundation
import Combine

struct ArchivePasswordRequest: Identifiable, Equatable {
    let id = UUID()
    let taskID: UUID
    let name: String
    let retry: Bool
}

@MainActor
final class CloudExtractionActivity: ObservableObject {
    @Published var tasks: [CloudExtractionTask] = []
    @Published var passwordRequest: ArchivePasswordRequest?
    @Published var showsActivity = false
    var passwordPresentationIsClosing = false

    var activeCount: Int { tasks.filter(\.isBusy).count }
    var needsAttention: Bool { tasks.contains { $0.needsPassword || $0.error != nil } }
    var summary: String {
        let extracting = tasks.filter(\.isExtracting).count
        if extracting == 1, let task = tasks.first(where: \.isExtracting), task.hasReportedProgress {
            return "Extracting \(Int(task.progress))%"
        }
        if extracting > 0 { return "Extracting \(extracting)" }
        let inspecting = tasks.filter(\.isInspecting).count
        if inspecting > 0 { return "Preparing \(inspecting)" }
        let queued = tasks.filter { $0.queuedAction != nil }.count
        if queued > 0 { return "\(queued) queued" }
        let locked = tasks.filter(\.needsPassword).count
        if locked > 0 { return locked == 1 ? "Password needed" : "\(locked) need passwords" }
        let failed = tasks.filter { $0.error != nil }.count
        if failed > 0 { return "\(failed) extraction\(failed == 1 ? "" : "s") failed" }
        let completed = tasks.filter(\.isComplete).count
        return completed > 0 ? "\(completed) extracted" : "Extractions"
    }
}

enum ArchiveQueuedAction { case inspect, extract }

/// Each archive owns its inspection, draft input and extraction status.
/// Passwords are memory-only, available for retries, and cleared on completion.
struct CloudExtractionTask: Identifiable {
    let id: UUID
    let item: BrowserItem
    let parentFolderID: String?
    var inspection: ArchiveInspection?
    var result: ArchiveExtractionResult?
    var error: AppErrorDiagnostic?
    var isInspecting = false
    var isExtracting = false
    var progress: Double = 0
    var hasReportedProgress = false
    var phase = ""
    var password = ""
    var selectedIndices = Set<Int>()
    var generation = UUID()
    var queuedAction: ArchiveQueuedAction?
    var extractWhenReady = false
    var passwordWasAttempted = false
    var passwordPromptDeferred = false

    var isBusy: Bool { isInspecting || isExtracting || queuedAction != nil }
    var needsPassword: Bool { !isBusy && !isComplete && inspection?.requiredPassword == true }
    var isComplete: Bool { result != nil || (inspection?.ready == true && inspection?.entries.isEmpty == true) }
    var statusText: String {
        if isInspecting { return "Reading archive…" }
        if isExtracting {
            return (hasReportedProgress ? "\(Int(progress))% · " : "")
                + (phase.isEmpty ? "Extracting in PikPak" : phase)
        }
        if let queuedAction { return queuedAction == .inspect ? "Queued for inspection" : "Queued for extraction" }
        if result != nil { return "Complete" }
        if error != nil { return "Needs attention" }
        if inspection?.requiredPassword == true { return "Password required" }
        if inspection?.ready == true { return inspection?.entries.isEmpty == true ? "Archive is empty" : "Ready to extract" }
        return phase.isEmpty ? "Waiting" : phase
    }
}
