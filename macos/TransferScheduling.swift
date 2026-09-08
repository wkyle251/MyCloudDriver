import AppKit
import Foundation
import UniformTypeIdentifiers

/// A click is a queue-edit operation, not a concurrency boundary. Gather all
/// compatible waiting selections into the next worker pool; leave selections
/// for other destinations/share sessions in their original relative order.
enum DownloadQueueBatching {
    /// Keep overlapping local trees in separate runs to avoid concurrent
    /// writers targeting the same files on a case-insensitive macOS volume.
    static func destinationsOverlap(_ first: [[String]], _ second: [[String]]) -> Bool {
        func key(_ components: [String]) -> [String] {
            components.map { ($0 as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
        }
        let first = first.map(key), second = second.map(key)
        return first.contains { a in second.contains { b in a.starts(with: b) || b.starts(with: a) } }
    }

    /// Compute destinations before merging clicks, so combining selections
    /// from different source folders never changes their local folder layout.
    static func relativeParents(for paths: [String]) -> [[String]] {
        let parents = paths.map { Array($0.split(separator: "/").map(String.init).dropLast()) }
        guard let first = parents.first else { return [] }
        let commonDepth = first.indices.prefix { index in
            parents.allSatisfy { $0.indices.contains(index) && $0[index] == first[index] }
        }.count
        return parents.map { Array($0.dropFirst(commonDepth)) }
    }

    static func takeNext<Request>(from queue: inout [Request],
                                  combining: (Request, Request) -> Request?) -> Request? {
        guard !queue.isEmpty else { return nil }
        var batch = queue.removeFirst()
        var waiting: [Request] = []
        for request in queue {
            if let combined = combining(batch, request) {
                batch = combined
            } else {
                waiting.append(request)
            }
        }
        queue = waiting
        return batch
    }
}

enum UploadAvailability {
    /// Downloads and read-only scans are deliberately not inputs. They own
    /// different processes and share the app's locked token-rotation store.
    static func allowsStart(hasSession: Bool, uploadActive: Bool,
                            conflictingMutation: Bool, foregroundAllows: Bool) -> Bool {
        hasSession && !uploadActive && !conflictingMutation && foregroundAllows
    }
}

/// Finder may supply NSURL, URL, serialized file-URL data or an NSString.
/// Preserve provider order, wait for every provider, and complete on main so
/// the captured cloud destination and transfer-tab callback remain consistent.
enum LocalUploadFileURLLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        loadResult(providers) { completion((try? $0.get()) ?? []) }
    }

    static func loadResult(_ providers: [NSItemProvider], completion: @escaping (Result<[URL], Error>) -> Void) {
        guard !providers.isEmpty else {
            DispatchQueue.main.async { completion(.failure(FinderDropError("The drop contains no local files or folders."))) }
            return
        }
        let batch = FinderURLBatch(count: providers.count, completion: completion)
        for (index, provider) in providers.enumerated() {
            // Start both supported representations while performDrop still
            // grants access. Some data providers advertise NSURL reading but
            // cannot coerce their result; others need the typed URL reader.
            // Starting a fallback only after an async error can be too late.
            let canReadURL = provider.canLoadObject(ofClass: NSURL.self)
            let read = FinderURLProviderRead(count: canReadURL ? 2 : 1) { url, error in
                batch.receive(index: index, url: url, error: error)
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                read.receive(url: localFileURL(from: item), error: error)
            }
            if canReadURL {
                provider.loadObject(ofClass: NSURL.self) { object, error in
                    read.receive(url: object as? URL, error: error)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { batch.timeOut() }
    }

    /// All-or-nothing validation prevents a "successful" drop silently losing
    /// some of the selected files. Folder selection already includes children,
    /// so a child selected alongside its parent must not upload twice.
    static func validatedRoots(_ items: [URL]) throws -> [URL] {
        var roots: [(url: URL, isDirectory: Bool)] = []
        var seen = Set<String>()
        for item in items {
            guard item.isFileURL, item.host == nil || item.host == "" || item.host == "localhost" else {
                throw FinderDropError("The drop contains a non-local URL. Drag files or folders from Finder instead.")
            }
            let url = item.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw FinderDropError("Cannot read \(url.lastPathComponent). No files from this drop were uploaded. Check Finder permissions and try again.")
            }
            roots.append((url, directory.boolValue))
        }
        guard !roots.isEmpty else { throw FinderDropError("The drop contains no readable local files or folders.") }
        return roots.filter { entry in
            !roots.contains { parent in
                parent.isDirectory && parent.url != entry.url
                    && entry.url.pathComponents.starts(with: parent.url.pathComponents)
            }
        }.map(\.url)
    }

    static func localFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let value = item as? String { return URL(string: value) }
        return nil
    }
}

private struct FinderDropError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Either URL representation may win, but one provider must complete exactly
/// once. A failed representation cannot discard another still-valid read.
private final class FinderURLProviderRead: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var failure: Error?
    private var finished = false
    private let completion: (URL?, Error?) -> Void

    init(count: Int, completion: @escaping (URL?, Error?) -> Void) {
        remaining = count
        self.completion = completion
    }

    func receive(url: URL?, error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        remaining -= 1
        if error == nil, let url, url.isFileURL {
            finished = true
            lock.unlock()
            completion(url, nil)
        } else {
            if let error { failure = error }
            guard remaining == 0 else { lock.unlock(); return }
            finished = true
            let error = failure
            lock.unlock()
            completion(nil, error)
        }
    }
}

private final class FinderURLBatch: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private let completion: (Result<[URL], Error>) -> Void
    private var received = Set<Int>()
    private var urls: [Int: URL] = [:]
    private var failure: Error?
    private var finished = false

    init(count: Int, completion: @escaping (Result<[URL], Error>) -> Void) {
        self.count = count
        self.completion = completion
    }

    func receive(index: Int, url: URL?, error: Error?) {
        lock.lock()
        guard !finished, received.insert(index).inserted else { lock.unlock(); return }
        if error == nil, let url, url.isFileURL {
            urls[index] = url
        } else {
            failure = error ?? FinderDropError("Finder could not supply every selected file. Nothing from this drop was uploaded; try dragging the selection again.")
        }
        guard received.count == count else { lock.unlock(); return }
        finished = true
        let result: Result<[URL], Error> = failure.map { .failure($0) }
            ?? .success((0..<count).compactMap { urls[$0] })
        lock.unlock()
        DispatchQueue.main.async { self.completion(result) }
    }

    func timeOut() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        DispatchQueue.main.async {
            self.completion(.failure(FinderDropError("Finder took too long to supply the selected files. Nothing from this drop was uploaded; try again.")))
        }
    }
}
