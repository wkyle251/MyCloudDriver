import Foundation
import UniformTypeIdentifiers

extension DownloaderModel {
    /// Reuse the Browser's search-result navigation so full cloud ancestry,
    /// selection, focus and scroll positioning use the same path as Find.
    @MainActor func revealSimilarityInBrowser(_ file: SimilarityFile) {
        guard let id = file.cloudId else {
            fileSimilarity.cloud.error = "This result does not include a PikPak file location. Scan the folder again."
            return
        }
        let ancestors = file.ancestors.map { FileSearchAncestor(id: $0.id, name: $0.name) }
        let item = FileSearchItem(id: id, name: file.name, kind: "drive#file", size: file.bytes,
                                 mimeType: UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType,
                                 modifiedTime: nil)
        let match = FileSearchMatch(item: item, ancestors: ancestors, score: 0)
        let directories = (0...ancestors.count).map { index -> FileSearchDirectory in
            let child = index == ancestors.count ? item : FileSearchItem(id: ancestors[index].id,
                name: ancestors[index].name, kind: "drive#folder", size: 0, mimeType: nil, modifiedTime: nil)
            return .init(parentID: index == 0 ? "" : ancestors[index - 1].id,
                ancestors: Array(ancestors.prefix(index)), items: [child], isLoaded: false, nextPageToken: nil)
        }
        let navigation = FileSearchNavigation(match: match, ancestors: ancestors, items: [item],
            hasLoadedDirectory: false, nextPageToken: nil, directories: directories, scope: .root)
        let accountID = activeAccountID, parentID = ancestors.last?.id ?? ""
        fileSimilarity.browserRevealTask?.cancel()
        fileSimilarity.browserRevealTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.isRunning { try await Task.sleep(nanoseconds: 40_000_000) }
                try Task.checkCancellation()
                guard self.activeAccountID == accountID else { return }
                let alreadyVisible = !self.isBrowsingSharedLink && self.browserStack.last?.id == parentID
                    && self.browserItems.contains(where: { $0.id == id })
                self.revealFileSearchResult(navigation)
                if !alreadyVisible {
                    if parentID.isEmpty { self.loadRoot() }
                    else if let parent = self.browserTreeEntries.first(where: { $0.item.id == parentID })?.item {
                        self.openFolder(parent)
                    } else { return }
                    var pages = Set<String>()
                    while true {
                        while self.isRunning { try await Task.sleep(nanoseconds: 40_000_000) }
                        try Task.checkCancellation()
                        guard self.activeAccountID == accountID, !self.isBrowsingSharedLink,
                              self.browserStack.last?.id == parentID else { return }
                        if self.browserItems.contains(where: { $0.id == id }) { break }
                        guard let token = self.nextPageToken, !token.isEmpty, pages.insert(token).inserted else {
                            self.fileSimilarity.cloud.error = "This file is no longer in its original PikPak folder. Refresh the scan to check its new location."
                            return
                        }
                        self.loadMoreBrowserItems()
                    }
                }
                // Use the standard reveal path for focus and scroll position,
                // retaining the real sibling listing loaded above.
                self.revealFileSearchResult(navigation)
            } catch { }
        }
    }
}
