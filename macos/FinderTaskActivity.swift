import SwiftUI

enum FinderTaskKind: String, CaseIterable, Identifiable {
    case duplicates, emptyFolders, dsStore, folderMerge, similarityCloud, similarityLocal
    var id: Self { self }
    var title: String {
        switch self {
        case .duplicates: return "Check Duplicates"
        case .emptyFolders: return "Remove Empty Folders"
        case .dsStore: return "Remove .DS_Store Files"
        case .folderMerge: return "Merge Folders"
        case .similarityCloud: return "Similar Files · PikPak Cloud"
        case .similarityLocal: return "Similar Files · This Mac"
        }
    }
    var symbol: String {
        switch self {
        case .duplicates: return "doc.on.doc"
        case .emptyFolders: return "folder.badge.minus"
        case .dsStore: return "doc.badge.minus"
        case .folderMerge: return "arrow.triangle.merge"
        case .similarityCloud, .similarityLocal: return "doc.text.magnifyingglass"
        }
    }
}

struct FinderTaskActivity: Identifiable {
    enum State {
        case running, stopping, completed, partial, cancelled, failed
        var isActive: Bool { self == .running || self == .stopping }
        var label: String {
            switch self {
            case .running: return "In progress"
            case .stopping: return "Stopping…"
            case .completed: return "Completed"
            case .partial: return "Partial results"
            case .cancelled: return "Cancelled"
            case .failed: return "Failed"
            }
        }
    }

    let kind: FinderTaskKind
    let scope: String
    var state: State = .running
    var message: String
    var detail = ""
    var fraction: Double?
    var diagnostic: AppErrorDiagnostic?
    var id: FinderTaskKind { kind }
}

/// The most recent run of each File-menu operation stays available after
/// navigation or unrelated status messages. Progress only invalidates the
/// footer, rather than publishing changes to every Browser row.
@MainActor
final class FinderTaskActivityStore: ObservableObject {
    @Published private(set) var tasks: [FinderTaskActivity] = []
    @Published var showsDetails = false
    @Published var showsDuplicateResults = false

    var activeTasks: [FinderTaskActivity] { tasks.filter { $0.state.isActive } }
    var summary: String? {
        let active = activeTasks
        if active.count > 1 { return "\(active.count) operations in progress" }
        return active.first?.message ?? tasks.first?.message
    }

    func begin(_ kind: FinderTaskKind, scope: String, message: String) {
        tasks.removeAll { $0.kind == kind }
        tasks.insert(FinderTaskActivity(kind: kind, scope: scope, message: message), at: 0)
    }

    func update(_ kind: FinderTaskKind, message: String, detail: String = "", fraction: Double? = nil) {
        guard let index = tasks.firstIndex(where: { $0.kind == kind && $0.state == .running }) else { return }
        var task = tasks[index]
        task.message = message
        task.detail = detail
        task.fraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        tasks[index] = task
    }

    func stopping(_ kind: FinderTaskKind, message: String) {
        guard let index = tasks.firstIndex(where: { $0.kind == kind && $0.state.isActive }) else { return }
        var task = tasks[index]
        task.state = .stopping
        task.message = message
        tasks[index] = task
    }

    func finish(_ kind: FinderTaskKind, state: FinderTaskActivity.State, message: String,
                detail: String? = nil, diagnostic: AppErrorDiagnostic? = nil) {
        guard !state.isActive, let index = tasks.firstIndex(where: { $0.kind == kind }) else { return }
        var task = tasks[index]
        task.state = state
        task.message = message
        if let detail { task.detail = detail }
        task.fraction = nil
        task.diagnostic = diagnostic
        tasks[index] = task
    }

    func dismiss(_ kind: FinderTaskKind) {
        tasks.removeAll { $0.kind == kind && !$0.state.isActive }
    }

    func reset(keeping kinds: Set<FinderTaskKind> = []) {
        tasks.removeAll { !kinds.contains($0.kind) }
        showsDetails = false
        showsDuplicateResults = false
    }
}

struct FinderTaskActivityRows: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var activity: FinderTaskActivityStore

    var body: some View {
        ForEach(activity.tasks) { task in
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: task.kind.symbol).foregroundStyle(FinderAppearance.accent)
                    Text(task.kind.title).font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(task.state.label).font(.caption).foregroundStyle(tint(for: task))
                }
                Text(task.scope).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).help(task.scope)
                if task.state.isActive {
                    ProgressView(value: task.fraction).progressViewStyle(.linear)
                        .tint(FinderAppearance.accent)
                }
                Text(task.message).font(.callout).textSelection(.enabled)
                    .foregroundStyle(task.state == .failed ? Color.red : Color.primary)
                if !task.detail.isEmpty {
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let diagnostic = task.diagnostic {
                    ErrorDiagnosticBlock(diagnostic: diagnostic, summary: task.message)
                }
                HStack {
                    if task.kind == .similarityCloud || task.kind == .similarityLocal {
                        Button(task.state.isActive ? "Show Scan…" : "Review Results…") {
                            activity.showsDetails = false
                            model.fileSimilarity.present(source: task.kind == .similarityCloud ? .cloud : .local)
                        }
                    }
                    if task.state.isActive {
                        Button("Cancel") { cancel(task.kind) }
                            .disabled(task.state == .stopping)
                            .help("Cancel \(task.kind.title.lowercased())")
                    } else {
                        if task.kind == .duplicates, model.duplicateScan != nil {
                            Button("Review Results…") {
                                activity.showsDetails = false
                                activity.showsDuplicateResults = true
                            }.help("Review duplicate groups and choose which copies to keep")
                        }
                        if task.kind == .folderMerge, model.canRetryFolderMerge {
                            Button("Retry Remaining") { model.retryFolderMerge() }
                                .help("Retry only unfinished source folders")
                        }
                        Spacer()
                        Button("Dismiss") { activity.dismiss(task.kind) }
                            .help("Dismiss this status; duplicate results remain available in File")
                    }
                }
                .font(.caption).buttonStyle(.borderless).pointingHandCursor()
            }
            .padding(12)
            .background(FinderAppearance.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func tint(for task: FinderTaskActivity) -> Color {
        switch task.state {
        case .failed: return .red
        case .partial: return .orange
        case .completed: return .green
        case .running: return FinderAppearance.accent
        case .stopping, .cancelled: return .secondary
        }
    }

    private func cancel(_ kind: FinderTaskKind) {
        switch kind {
        case .duplicates: model.cancelDuplicateScan()
        case .emptyFolders, .dsStore: model.cancelMaintenanceScan()
        case .folderMerge: model.cancelFolderMerge()
        case .similarityCloud: model.fileSimilarity.cloud.cancel()
        case .similarityLocal: model.fileSimilarity.local.cancel()
        }
    }
}
