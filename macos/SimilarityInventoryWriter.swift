import Foundation
import Darwin

/// Append metadata as discovery yields it. Originals never enter this stream.
/// The helper can read complete lines while this actor appends later files.
actor SimilarityInventoryWriter {
    nonisolated static func refreshURL(event: [String: Any], sourceRoot: URL) -> URL? {
        guard let path = event["inventory_file"] as? String, path.hasPrefix("/") else { return nil }
        let raw = URL(fileURLWithPath: path)
        let directory = sourceRoot.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard raw.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == directory,
              raw.lastPathComponent.hasPrefix("inventory-"), raw.pathExtension == "jsonl",
              let values = try? raw.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 0 else { return nil }
        return directory.appendingPathComponent(raw.lastPathComponent)
    }
    private var handle: FileHandle?
    private struct Line: Encodable {
        let event: String
        var file: SimilarityExternalSource?
        var message: String?
    }
    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              ftruncate(descriptor, 0) == 0 else {
            Darwin.close(descriptor); throw CocoaError(.fileWriteNoPermission)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private func write(_ line: Line) throws {
        guard let handle else { throw CancellationError() }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(line); data.append(0x0a)
        try handle.write(contentsOf: data)
    }
    func append(_ file: SimilarityExternalSource) throws { try write(.init(event: "file", file: file)) }
    func finish(error: String? = nil) throws {
        defer { try? handle?.close(); handle = nil }
        try write(.init(event: error == nil ? "complete" : "error", message: error))
    }
    func close() { try? handle?.close(); handle = nil }
    deinit { try? handle?.close() }
}
