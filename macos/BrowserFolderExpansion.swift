import AppKit
import SwiftUI

struct BrowserFolderExpansionProgress: Equatable {
    let rootName: String
    let levels: Int?
    let loadedFolders: Int
    let discoveredFolders: Int
    let failedFolders: Int

    var summary: String {
        let depth = levels.map { "\($0) \($0 == 1 ? "level" : "levels")" } ?? "all levels"
        return "Expanding \(rootName) · \(depth)"
    }
}

/// A bounded, breadth-first expansion plan over one or more selected folders.
/// Folder listings use the Browser's existing read-only helper lane; this state
/// machine never performs network requests or changes selection. Every root is
/// depth zero, so a depth of one opens each root and its immediate subfolders.
final class BrowserFolderExpansionPlan {
    struct Folder {
        let id: String
        let depth: Int
    }

    private enum Page: Hashable { case first, next(String) }

    let id = UUID()
    let rootIDs: [String]
    let rootName: String
    let levels: Int?
    private var work: [String: Folder] = [:]
    private var discovered = Set<String>()
    private var ready: [String] = []
    private var readyIndex = 0
    private var readyIDs = Set<String>()
    private var requestedPages: [String: Set<Page>] = [:]
    private(set) var loadedFolders = 0
    private(set) var failedFolders = 0

    convenience init(rootID: String, rootName: String, levels: Int?) {
        self.init(roots: [(rootID, rootName)], levels: levels)
    }

    /// Roots are seeded in order and deduplicated by id, so a folder selected
    /// alongside one of its own ancestors is still only expanded once.
    init(roots: [(id: String, name: String)], levels: Int?) {
        self.rootIDs = roots.map(\.id)
        self.rootName = roots.count == 1 ? roots[0].name : "\(roots.count) folders"
        self.levels = levels.map { max(1, $0) }
        for root in roots { discover(root.id, depth: 0) }
    }

    var isFinished: Bool { work.isEmpty }
    var hasReadyFolders: Bool { !readyIDs.isEmpty }
    var progress: BrowserFolderExpansionProgress {
        .init(rootName: rootName, levels: levels, loadedFolders: loadedFolders,
              discoveredFolders: discovered.count, failedFolders: failedFolders)
    }

    func contains(_ folderID: String) -> Bool { discovered.contains(folderID) }
    func isWaiting(for folderID: String) -> Bool { work[folderID] != nil }

    func nextFolder() -> Folder? {
        while readyIndex < ready.count {
            let folderID = ready[readyIndex]
            readyIndex += 1
            readyIDs.remove(folderID)
            if let folder = work[folderID] { return folder }
        }
        ready = []
        readyIndex = 0
        return nil
    }

    /// Every page contributes children immediately; a folder isn't complete
    /// until its last page arrives. IDs, not names, suppress repeats/cycles.
    func discoverChildren(of folderID: String, folderIDs: [String]) {
        guard let folder = work[folderID],
              levels.map({ folder.depth < $0 }) ?? true else { return }
        for childID in folderIDs { discover(childID, depth: folder.depth + 1) }
    }

    func resume(_ folderID: String) {
        guard work[folderID] != nil, readyIDs.insert(folderID).inserted else { return }
        ready.append(folderID)
    }

    /// A repeated API page token must not trap All Levels in an endless loop.
    func claimPage(for folderID: String, token: String?) -> Bool {
        let page = token.map(Page.next) ?? .first
        return requestedPages[folderID, default: []].insert(page).inserted
    }

    func finish(_ folderID: String, failed: Bool = false) {
        guard work.removeValue(forKey: folderID) != nil else { return }
        requestedPages.removeValue(forKey: folderID)
        if failed { failedFolders += 1 } else { loadedFolders += 1 }
    }

    private func discover(_ folderID: String, depth: Int) {
        guard discovered.insert(folderID).inserted else { return }
        work[folderID] = Folder(id: folderID, depth: depth)
        resume(folderID)
    }
}

/// The context menu expands the complete tree with one action. Row disclosure
/// controls still open or close individual folders.
struct BrowserFolderExpansionAction: View {
    /// A menu opened on a row inside a multi-folder selection expands the whole
    /// selection, so the title names how many folders the action will open.
    static func title(folderCount: Int) -> String {
        folderCount > 1 ? "Expand All Levels in \(folderCount) Folders" : "Expand All Levels"
    }

    var folderCount = 1
    let onExpand: (Int?) -> Void

    @MainActor static func add(to menu: BrowserNativeMenu, enabled: Bool = true, folderCount: Int = 1,
                               onExpand: @escaping (Int?) -> Void) {
        menu.addAction(title(folderCount: folderCount), symbol: "chevron.right", enabled: enabled) { onExpand(nil) }
    }

    var body: some View {
        Button { onExpand(nil) } label: {
            BrowserContextMenuStyle.label(Self.title(folderCount: folderCount), systemImage: "chevron.right")
        }
        .help(folderCount > 1
              ? "Expand every selected folder and all of their nested subfolders."
              : "Expand this folder and every nested subfolder.")
    }
}

struct BrowserFolderExpansionBar: View {
    let progress: BrowserFolderExpansionProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(progress.summary)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(progress.summary)
                Text("\(progress.loadedFolders.formatted()) loaded · \(progress.discoveredFolders.formatted()) discovered"
                     + (progress.failedFolders > 0 ? " · \(progress.failedFolders.formatted()) failed" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", action: onCancel)
                .help("Stop loading more subfolders; keep folders already opened.")
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
    }
}
