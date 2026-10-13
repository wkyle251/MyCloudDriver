import Foundation
import UniformTypeIdentifiers

/// Generated folders only. Listing a large folder must not pay for iCloud information that an ordinary
/// folder cannot have, and must produce exactly the rows it always did.
@main struct NativeListingTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let folder = FileManager.default.temporaryDirectory
        let ordinary = ICloudDriveProvider.listingKeys(for: folder, kind: .local, isUbiquitous: { _ in false })
        precondition(!ordinary.contains(.isUbiquitousItemKey) && !ordinary.contains(.ubiquitousItemDownloadingStatusKey),
                     "An ordinary folder is listed without the slow iCloud-only keys")
        precondition(ordinary.isSuperset(of: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                              .contentModificationDateKey, .isHiddenKey]) && ordinary.isSubset(of: ICloudDriveProvider.keys))
        let cloud = ICloudDriveProvider.listingKeys(for: folder, kind: .local, isUbiquitous: { _ in true })
        precondition(cloud == ICloudDriveProvider.keys, "A folder that is in iCloud keeps every key, even when browsed as Local Disk")
        precondition(ICloudDriveProvider.listingKeys(for: folder, kind: .icloud, isUbiquitous: { _ in false }) == ICloudDriveProvider.keys,
                     "The iCloud Drive browser always keeps every key")
        print("PASS listing keys: iCloud-only keys only for iCloud Drive or a folder that is in iCloud")

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NativeListingTests-\(UUID().uuidString)")
        try manager.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for name in ["a.jpg", "b.MOV", "c.txt", "d.mp3", ".hidden.txt"] {
            try Data("generated \(name)".utf8).write(to: root.appendingPathComponent(name))
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("link.jpg"), withDestinationURL: root.appendingPathComponent("a.jpg"))
        let provider = ICloudDriveProvider(rootURL: root, kind: .local)
        let page = try await provider.list(provider.root, offset: 0, search: "")
        precondition(page.items.map(\.name) == ["Sub", "a.jpg", "b.MOV", "c.txt", "d.mp3"] && page.total == 5 && page.nextOffset == nil,
                     "Folders first, then names; links and hidden files stay out: \(page.items.map(\.name))")
        precondition(page.items.allSatisfy { $0.isDownloaded && $0.modified != nil && $0.url != nil })
        precondition(page.items.filter { !$0.isFolder }.allSatisfy { $0.revision != nil && $0.bytes != nil }, "Files keep the revision and size they were listed with")
        precondition(page.items.map(\.mediaType) == ["file", "image", "video", "file", "audio"])
        for item in page.items {
            let reference = try ICloudDriveProvider.item(listed: item.url!, in: root)
            precondition(item == reference, "A listed row equals the row built with every key: \(item.name)")
        }
        let filtered = try await provider.list(provider.root, offset: 0, search: "txt")
        precondition(filtered.items.map(\.name) == ["c.txt"], "Searching still filters by name")
        print("PASS listing an ordinary folder gives the same rows, sizes, revisions and types as before")

        func reference(_ ext: String) -> String {
            let type = UTType(filenameExtension: ext)
            return type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video"
                : type?.conforms(to: .audio) == true ? "audio" : "file"
        }
        let extensions = ["jpg", "JPG", "jpeg", "heic", "mov", "MOV", "mp4", "mp3", "m4a", "txt", "pdf", "zip", "", "no-such-extension-1234", "日本語"]
        for ext in extensions + extensions {
            precondition(ICloudDriveProvider.mediaType(forExtension: ext) == reference(ext), "Type for .\(ext) must not change when it is remembered")
        }
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0..<500 {
                let ext = extensions[(worker + round) % extensions.count]
                precondition(ICloudDriveProvider.mediaType(forExtension: ext) == reference(ext))
            }
        }
        for index in 0..<5_000 { _ = ICloudDriveProvider.mediaType(forExtension: "unique-\(index)") }
        precondition(ICloudDriveProvider.mediaType(forExtension: "jpg") == "image", "A flood of unusual extensions cannot break the remembered ones")
        print("PASS file types are remembered per extension, identical to the direct lookup, safe from many threads and bounded")
    }
}
