import AppKit
import Foundation

@main struct NativeFileSearchMetadataTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NativeSearchMetadata-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let unreadable = root.appendingPathComponent("generated-unreadable.txt")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
            try? fm.removeItem(at: root)
        }
        try Data(repeating: 65, count: 37).write(to: unreadable)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        try Data([66]).write(to: root.appendingPathComponent(".generated-hidden"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("generated-link"), withDestinationURL: unreadable)
        let nested = root.appendingPathComponent("Generated Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([67]).write(to: nested.appendingPathComponent("generated-descendant.txt"))
        let provider = ICloudDriveProvider(rootURL: root, kind: .local)
        let page = try await provider.searchPage(provider.root, offset: 0)
        precondition(page.items.count == 2 && page.total == 2 && page.nextOffset == nil)
        precondition(page.items.allSatisfy { $0.revision == nil && $0.url?.deletingLastPathComponent().path == root.path })
        precondition(page.items.allSatisfy { !$0.isDownloaded }, "Search-only metadata must not authorize original thumbnail reads")
        precondition(page.items.contains { $0.name == unreadable.lastPathComponent && $0.bytes == 37 && !$0.isFolder })
        let folder = page.items.first { $0.isFolder }!
        let child = try await provider.searchPage(folder.location, offset: 0)
        precondition(child.items.count == 1 && child.items[0].bytes == 1)
        precondition(child.items.allSatisfy { !$0.isDownloaded })
        let later = try await provider.searchPage(provider.root, offset: 1)
        precondition(later.items.isEmpty && later.nextOffset == nil)
        print("PASS generated metadata search includes unreadable file names and folders, excludes hidden/symbolic entries and retains no file revisions")

        let cancelled = Task { try await provider.searchPage(provider.root, offset: 0) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled metadata work must not publish a page") }
        catch is CancellationError { }
        let foreign = root.deletingLastPathComponent().appendingPathComponent("Generated Outside-\(UUID())")
        do {
            _ = try await provider.searchPage(.init(id: foreign.absoluteString, title: "Generated", url: foreign), offset: 0)
            preconditionFailure("Search must stay within its captured root")
        } catch { }
        print("PASS cancelled metadata search and out-of-root requests are rejected")

        let large = root.appendingPathComponent("Generated Large", isDirectory: true)
        try fm.createDirectory(at: large, withIntermediateDirectories: true)
        try await NativeFileWork.run {
            for index in 0..<5_000 {
                guard fm.createFile(atPath: large.appendingPathComponent("generated-\(index).txt").path, contents: Data([68])) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        let largeProvider = ICloudDriveProvider(rootURL: large, kind: .local)
        var heartbeats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
                heartbeats += 1
            }
        }
        let largePage = try await largeProvider.searchPage(largeProvider.root, offset: 0)
        heartbeat.cancel()
        precondition(largePage.items.count == 5_000 && heartbeats > 0)
        precondition(largePage.items.allSatisfy { $0.revision == nil && !$0.isDownloaded })
        print("PASS 5,000 generated names are enumerated while the main actor remains responsive")
    }
}
