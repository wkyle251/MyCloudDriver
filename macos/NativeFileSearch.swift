import Foundation

/// Name-only provider pages. Original contents, revisions and download links
/// never enter the search scanner or its index.
struct NativeFileSearchPage: Sendable {
    let items: [FileSearchItem]
    var nextOffset: Int? = nil
}

enum NativeFileSearch {
    typealias PageLoader = @Sendable (_ parentID: String, _ offset: Int) async throws -> NativeFileSearchPage

    static func scanFactory(rootID: String, loadPage: @escaping PageLoader) -> FileSearchScanFactory {
        { onEvent, onFinish in
            NativeFileSearchJob(rootID: rootID, loadPage: loadPage, onEvent: onEvent, onFinish: onFinish)
        }
    }

    private struct Request: Sendable {
        let parentID: String
        let offset: Int
        let ancestors: [FileSearchAncestor]
    }

    fileprivate static func scan(rootID: String, loadPage: @escaping PageLoader,
                                 emit: @escaping (FileSearchEvent) -> Void) async {
        let root = Request(parentID: rootID, offset: 0, ancestors: [])
        var pending = [root], pendingOffset = 0
        var seenItems: Set<String> = [rootID]
        var seenFolders: Set<String> = [rootID]
        var offsets: [String: Set<Int>] = [rootID: [0]]
        var progress = FileSearchProgress(discoveredFolders: 1)
        await withTaskGroup(of: (Request, Result<NativeFileSearchPage, Error>).self) { group in
            var running = 0
            while !Task.isCancelled {
                while running < 2 && pendingOffset < pending.count && !Task.isCancelled {
                    let request = pending[pendingOffset]
                    pendingOffset += 1
                    running += 1
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let page = try await loadPage(request.parentID, request.offset)
                            try Task.checkCancellation()
                            return (request, .success(page))
                        } catch { return (request, .failure(error)) }
                    }
                }
                // Release processed metadata jobs instead of retaining every
                // ancestor chain for the lifetime of a large root traversal.
                if pendingOffset > 1_024 && pendingOffset * 2 > pending.count {
                    pending.removeFirst(pendingOffset); pendingOffset = 0
                }
                guard running > 0, let (request, result) = await group.next() else { break }
                running -= 1
                guard !Task.isCancelled else { break }
                switch result {
                case .failure(let error):
                    progress.failedFolders += 1
                    emit(FileSearchEvent(event: "failure", parentId: nil, ancestors: request.ancestors,
                        items: nil, nextPageToken: nil, progress: progress,
                        code: "NATIVE_SEARCH_FOLDER_UNAVAILABLE",
                        message: FileSearchIndex.redacted(error.localizedDescription)))
                case .success(let page):
                    var items: [FileSearchItem] = []
                    for item in page.items where !item.id.isEmpty && seenItems.insert(item.id).inserted {
                        items.append(item); progress.indexedItems += 1
                        if item.isFolder && seenFolders.insert(item.id).inserted {
                            var ancestors = request.ancestors
                            ancestors.append(.init(id: item.id, name: item.name))
                            pending.append(Request(parentID: item.id, offset: 0, ancestors: ancestors))
                            offsets[item.id] = [0]
                            progress.discoveredFolders += 1
                        }
                    }
                    let next = page.nextOffset
                    let repeated = next.map { offset in
                        offset <= request.offset || !offsets[request.parentID, default: []].insert(offset).inserted
                    } ?? false
                    if next == nil { progress.scannedFolders += 1 }
                    emit(FileSearchEvent(event: "page", parentId: request.parentID == rootID ? "" : request.parentID,
                        ancestors: request.ancestors, items: items, nextPageToken: next.map(String.init),
                        progress: progress, code: nil, message: nil))
                    if repeated {
                        progress.failedFolders += 1
                        emit(FileSearchEvent(event: "failure", parentId: nil, ancestors: request.ancestors,
                            items: nil, nextPageToken: nil, progress: progress,
                            code: "NATIVE_SEARCH_REPEATED_PAGE",
                            message: "The drive repeated a directory page. Some results may be missing; scan again to retry."))
                    } else if let next {
                        pending.append(Request(parentID: request.parentID, offset: next, ancestors: request.ancestors))
                    }
                }
            }
            group.cancelAll()
        }
        guard !Task.isCancelled else { return }
        emit(FileSearchEvent(event: "finished", parentId: nil, ancestors: nil, items: nil,
            nextPageToken: nil, progress: progress, code: nil, message: nil))
    }
}

private final class NativeFileSearchJob: FileSearchScanJob, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var finished = false
    private let onEvent: (FileSearchEvent) -> Void
    private let onFinish: (Int32, String) -> Void
    var runningProcessIdentifier: Int32? { nil }

    init(rootID: String, loadPage: @escaping NativeFileSearch.PageLoader,
         onEvent: @escaping (FileSearchEvent) -> Void, onFinish: @escaping (Int32, String) -> Void) {
        self.onEvent = onEvent; self.onFinish = onFinish
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await NativeFileSearch.scan(rootID: rootID, loadPage: loadPage) { self.emit($0) }
            self.complete()
        }
    }
    private func emit(_ event: FileSearchEvent) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled && !finished else { return }
        onEvent(event)
    }
    private func complete() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled && !finished else { return }
        finished = true
        onFinish(0, "")
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}
