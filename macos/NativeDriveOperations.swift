import AppKit
import Foundation

@_silgen_name("mcd_archive_extract")
private func extractNativeArchive(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>, _ password: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer, _ progress: @convention(c) (UnsafeMutableRawPointer?, Int64, UnsafePointer<CChar>?) -> Int32,
    _ error: UnsafeMutablePointer<CChar>, _ capacity: Int) -> Int32

enum NativeArchiveError: Error { case passwordRequired }
private final class NativeArchiveProgress {
    let handler: CloudDriveProgressHandler
    let bytes: Int64
    var last = Date.distantPast
    init(handler: @escaping CloudDriveProgressHandler, bytes: Int64) { self.handler = handler; self.bytes = bytes }
}
enum NativeDriveArchive {
    static func extract(_ source: URL, to directory: URL, password: String?, progress: @escaping CloudDriveProgressHandler) async throws {
        try await CloudDriveFiles.detached {
            try CloudDriveFiles.privateDirectory(directory)
            do {
                try CloudDriveFiles.coordinated(source) { source in
                    let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    let context = NativeArchiveProgress(handler: progress, bytes: bytes)
                    let pointer = Unmanaged.passRetained(context).toOpaque()
                    defer { Unmanaged<NativeArchiveProgress>.fromOpaque(pointer).release() }
                    var error = [CChar](repeating: 0, count: 1024)
                    let callback: @convention(c) (UnsafeMutableRawPointer?, Int64, UnsafePointer<CChar>?) -> Int32 = { context, bytes, name in
                        if Task.isCancelled { return 1 }
                        guard let context else { return 1 }
                        let value = Unmanaged<NativeArchiveProgress>.fromOpaque(context).takeUnretainedValue()
                        if Date().timeIntervalSince(value.last) > 0.2 {
                            value.last = Date()
                            value.handler(.init(message: "Extracting \(name.map { String(cString: $0) } ?? "archive")",
                                fraction: value.bytes > 0 ? min(0.99, Double(bytes) / Double(value.bytes)) : nil))
                        }
                        return 0
                    }
                    let result = source.path.withCString { source in directory.path.withCString { destination in
                        (password ?? "").withCString { password in extractNativeArchive(source, destination, password, pointer, callback, &error, error.count) }
                    } }
                    if result == 2 { throw NativeArchiveError.passwordRequired }
                    if result == 3 { throw CancellationError() }
                    if result != 0 { throw CloudDriveError.message(String(cString: error)) }
                }
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
    }
}

extension CloudDriveUndo {
    static func sequence(_ steps: [CloudDriveUndo], title: String) -> CloudDriveUndo {
        .init(title: title) {
            var reverse: [CloudDriveUndo] = []
            do { for step in steps { reverse.append(try await step.apply()) } }
            catch { for rollback in reverse.reversed() { _ = try? await rollback.apply() }; throw error }
            return .sequence(Array(reverse.reversed()), title: title)
        }
    }
}

@MainActor extension NativeDriveModel {
    func reviewCleanup(empty: Bool) {
        let location = location
        run(empty ? "Find empty \(kind == .photos ? "albums" : "folders")" : "Find .DS_Store files") { [weak self] provider, progress in
            let candidates: [CloudDriveItem]
            if let files = provider as? ICloudDriveProvider { candidates = try await files.cleanupCandidates(in: location, empty: empty, progress: progress) }
            else if let photos = provider as? PhotosDriveProvider { candidates = try await photos.emptyAlbums(progress: progress) }
            else { throw CloudDriveError.message("Cleanup is unavailable for this connection.") }
            try Task.checkCancellation()
            guard let self else { return nil }
            guard !candidates.isEmpty else { progress(.init(message: empty ? "No empty containers found" : "No .DS_Store files found")); return nil }
            let confirmed = await Self.confirm(title: empty ? "Remove \(candidates.count) empty \(self.kind == .photos ? "albums" : "folders")?" : "Remove \(candidates.count) .DS_Store files?",
                message: candidates.prefix(8).map(\.name).joined(separator: "\n") + (candidates.count > 8 ? "\n…and \(candidates.count - 8) more." : ""), action: "Remove")
            try Task.checkCancellation()
            if confirmed {
                self.run(empty ? "Remove empty containers" : "Remove .DS_Store files", mutating: true) { provider, progress in
                    if let files = provider as? ICloudDriveProvider { return try await files.cleanup(candidates, empty: empty, progress: progress) }
                    if let photos = provider as? PhotosDriveProvider { return try await photos.removeEmptyAlbums(candidates, progress: progress) }
                    throw CloudDriveError.message("The drive connection changed.")
                }
            }
            return nil
        }
    }
    func reviewMerge(_ items: [CloudDriveItem]) {
        guard items.count > 1, items.allSatisfy(\.isFolder) else { return }
        let destination = items[0]
        Task {
            guard await Self.confirm(title: "Merge into “\(destination.name)”?",
                message: kind == .photos ? "Combine the selected albums into this album. Media stays in your library. You can undo the album change."
                : "Move the contents of the other selected folders into this folder, then remove the empty source folders. Conflicting names must be resolved first. You can undo this change.", action: "Merge") else { return }
            run("Merge \(kind == .photos ? "albums" : "folders")", mutating: true) { provider, progress in
                if let files = provider as? ICloudDriveProvider { return try await files.merge(items, progress: progress) }
                if let photos = provider as? PhotosDriveProvider { return try await photos.mergeAlbums(items, progress: progress) }
                throw CloudDriveError.message("Merging is unavailable for this connection.")
            }
        }
    }
    func extract(_ item: CloudDriveItem, password: String? = nil) {
        guard kind == .icloud, let source = item.url else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-Extraction-\(UUID().uuidString)")
        let target = source.deletingLastPathComponent(), name = source.deletingPathExtension().lastPathComponent
        run("Extract \(item.name)") { [weak self] provider, progress in
            defer { try? FileManager.default.removeItem(at: directory) }
            let materialized = try await provider.materialize(item, directory: directory, progress: progress)
            let result = directory.appendingPathComponent(FinderFileOpenStorage.safeFilename(name), isDirectory: true)
            var currentPassword = password
            while true {
                do { try await NativeDriveArchive.extract(materialized, to: result, password: currentPassword, progress: progress); break }
                catch NativeArchiveError.passwordRequired {
                    try Task.checkCancellation()
                    progress(.init(message: "Waiting for archive password"))
                    guard let next = await Self.requestPassword(for: item.name, retry: currentPassword != nil) else { throw CancellationError() }
                    currentPassword = next
                }
            }
            try Task.checkCancellation()
            let undo = try await provider.importFiles([result], into: .init(id: target.absoluteString, title: target.lastPathComponent, url: target), progress: progress)
            progress(.init(message: "Extracted \(item.name)", fraction: 1))
            self?.reload()
            return undo.map { .sequence([$0], title: "Extract Archive") }
        }
    }
    private static func confirm(title: String, message: String, action: String) async -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return false }
        return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) } }
    }
    private static func requestPassword(for name: String, retry: Bool) async -> String? {
        let alert = NSAlert(); alert.messageText = retry ? "Try another archive password" : "Archive password required"
        alert.informativeText = "Enter the password for “\(name)”. Extraction continues in the background."
        let field = NSSecureTextField(frame: .init(x: 0, y: 0, width: 330, height: 24)); field.placeholderString = "Password"
        alert.accessoryView = field; alert.addButton(withTitle: "Extract"); alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return nil }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                let value = field.stringValue; field.stringValue = ""
                continuation.resume(returning: response == .alertFirstButtonReturn ? value : nil)
            }
            alert.window.makeFirstResponder(field)
        }
    }
}
