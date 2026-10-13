import AppKit
import SwiftUI

private actor FilterTestDrive: NativeCloudDrive {
    nonisolated let kind: CloudDriveKind
    nonisolated let root = CloudDriveLocation(id: "root", title: "Filter Fixture")
    private(set) var calls = 0
    init(kind: CloudDriveKind) { self.kind = kind }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        calls += 1
        let all: [CloudDriveItem] = location.id == "folder" ? [
            .init(id: "nested-video", name: "Nested.mp4", isFolder: false),
            .init(id: "nested-text", name: "Notes.txt", isFolder: false)
        ] : [
            .init(id: "folder", name: "Projects", isFolder: true),
            .init(id: "text", name: "Readme.txt", isFolder: false),
            .init(id: "image", name: "Beach.JPG", isFolder: false),
            .init(id: "video", name: "Clip.MP4", isFolder: false),
            .init(id: "pdf", name: "Report.pdf", isFolder: false),
            .init(id: "archive", name: "Backup.zip", isFolder: false),
            .init(id: "extensionless", name: "Original", isFolder: false, mediaType: "image")
        ]
        let matches = all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let end = min(offset + 2, matches.count)
        return .init(items: Array(matches.dropFirst(offset).prefix(2)), total: matches.count,
                     nextOffset: end < matches.count ? end : nil)
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL { throw CocoaError(.featureUnsupported) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { throw CocoaError(.featureUnsupported) }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

@main struct BrowserFileFilterTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--ui") || Bundle.main.object(forInfoDictionaryKey: "FileFilterFixture") as? Bool == true {
            launchUI(); return
        }
        func item(_ name: String, mime: String? = nil, ext: String? = nil, folder: Bool = false) -> BrowserItem {
            .init(id: name, name: name, size: 1, kind: folder ? .folder : .file, parentId: nil,
                mimeType: mime, createdTime: nil, modifiedTime: nil, fileExtension: ext,
                iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        let fixtures: [(BrowserItem, BrowserFileCategory)] = [
            (item("Beach.JPG"), .images), (item("Original", mime: " IMAGE/HEIC ; charset=binary"), .images),
            (item("Film.mkv"), .videos), (item("Stream.ts", mime: "video/mp2t"), .videos),
            (item("types.ts", mime: "text/typescript"), .documents),
            (item("Song.FLAC"), .audio), (item("Paper.PDF"), .documents),
            (item("Book.epub", mime: "application/epub+zip"), .documents),
            (item("Report.docx"), .documents), (item("Data.csv"), .documents),
            (item("Backup.RAR"), .archives), (item("Backup.tar.gz"), .archives),
            (item("Archive", mime: "application/x-7z-compressed"), .archives),
            (item("Unknown.weirdformat"), .other), (item("README"), .other)
        ]
        for (file, expected) in fixtures {
            for category in BrowserFileCategory.allCases {
                precondition(BrowserFileFilter.category(category).matches(file) == (category == expected), "\(file.name): expected \(expected), checked \(category)")
            }
            precondition(BrowserFileFilter.all.matches(file))
        }
        precondition(BrowserFileFilter.fileExtension("jpg").matches(item("Beach.JPG")))
        precondition(BrowserFileFilter.fileExtension("jpg").matches(item("Original", ext: " .JPG ")))
        precondition(!BrowserFileFilter.fileExtension("jpg").matches(item("Beach.jpg.exe")))
        precondition(BrowserFileFilter.fileExtension("").matches(item("README")))
        precondition(BrowserFileFilter.fileExtension("").matches(item(".gitignore")))
        let folder = item("Albums.jpg", folder: true)
        precondition(BrowserFileFilter.all.matches(folder))
        for category in BrowserFileCategory.allCases { precondition(BrowserFileFilter.category(category).matches(folder), "\(category) hides a folder") }
        precondition(BrowserFileFilter.fileExtension("jpg").matches(folder))
        precondition(BrowserFileFilter.fileExtension("txt").matches(folder), "a folder stays visible under an extension it does not carry")
        precondition(BrowserFileFilter.category(.videos).matches(CloudDriveItem(id: "album", name: "Albums", isFolder: true)))
        precondition(BrowserFileFilter.category(.videos).matches(CloudDriveItem(id: "asset", name: "Original", isFolder: false, mediaType: "video")))
        print("PASS file types: all categories, case folding, MIME metadata, extensionless assets, compound suffixes and always-visible folders")

        let suite = "com.wky.MyCloudDriver.FileFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testBrowserFileFiltering(defaults: defaults)
        DownloaderModel.testBrowserFilterSelectionRetention(defaults: defaults)
        for kind in [CloudDriveKind.local, .icloud, .photos] { try await testNative(kind) }
    }

    @MainActor static func idle(_ model: NativeDriveModel) async throws {
        for _ in 0..<500 {
            if !model.isLoading && !model.tree.isLoading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Fixture did not finish loading")
    }

    @MainActor static func testNative(_ kind: CloudDriveKind) async throws {
        let drive = FilterTestDrive(kind: kind), model = NativeDriveModel(kind: kind, preferences: UserDefaults(suiteName: "com.wky.MyCloudDriver.FileFilterNative.\(UUID().uuidString)")!)
        // These checks are about the type filter itself, where every folder stays; hiding empty folders has its own suite.
        model.hidesEmptyFolders = false
        defer { model.close() }
        model.connect(drive); try await idle(model)
        let folder = model.items.first { $0.isFolder }!
        model.select(folder, extending: false, toggling: false)
        model.fileTypeFilter = .category(.videos)
        precondition(model.visibleRows.map { $0.item.id } == ["folder"], "folders stay visible while their files are filtered")
        precondition(model.selection == ["folder"] && model.nextOffset != nil, "a selected folder survives the filter")
        model.reload(append: true); try await idle(model)
        precondition(model.visibleRows.map { $0.item.id } == ["folder", "video"])
        while model.nextOffset != nil { model.reload(append: true); try await idle(model) }
        model.fileTypeFilter = .all
        model.toggleExpansion(folder); try await idle(model)
        let rawIDs = model.tree.rows.map(\.id), calls = await drive.calls
        model.fileTypeFilter = .category(.videos)
        precondition(model.visibleRows.map { $0.item.id } == ["folder", "nested-video", "video"],
                     "an expanded folder keeps its place above its matching files")
        model.moveSelection(1); model.moveSelection(1, extending: true)
        precondition(model.selection == ["nested-video", "video"])
        model.viewMode = 1
        precondition(model.visibleRows.map { $0.item.id } == ["folder", "video"] && model.selection == ["video"])
        model.viewMode = 0
        model.fileTypeFilter = .category(.images)
        precondition(model.visibleRows.map { $0.item.id } == ["folder", "image", "extensionless"] && model.selection.isEmpty)
        model.fileTypeFilter = .fileExtension("jpg")
        precondition(model.visibleRows.map { $0.item.id } == ["folder", "image"])
        precondition(Set(model.availableFileExtensions) == ["", "jpg", "mp4", "pdf", "txt", "zip"])
        model.fileTypeFilter = .all
        precondition(model.tree.rows.map(\.id) == rawIDs && model.visibleRows.map(\.id) == rawIDs)
        let afterCalls = await drive.calls
        precondition(afterCalls == calls, "Filtering must not load folders or fetch files")
        model.query = "report"; model.reload(); try await idle(model)
        model.fileTypeFilter = .category(.images)
        precondition(model.visibleRows.isEmpty, "a search result without folders can still filter down to nothing")
        model.fileTypeFilter = .category(.documents)
        precondition(model.visibleRows.map { $0.item.id } == ["pdf"], "type filtering composes with filename search")
        print("PASS \(kind.title): visible folders, pagination, expanded rows, keyboard selection, list/grid, reset, search and no filter I/O")
    }

    @MainActor static func launchUI() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "File Filter · Offline Fixture"
        window.contentView = NSHostingView(rootView: FilterFixtureView())
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); app.run()
    }
}

@MainActor private struct FilterFixtureView: View {
    private let defaults: UserDefaults
    @StateObject private var hub: CloudDriveHub
    private var model: DownloaderModel { hub.pikpak }
    private var native: NativeDriveModel { hub.photos }
    @State private var nativeView = false
    init() {
        let defaults = UserDefaults(suiteName: "com.wky.MyCloudDriver.FileFilterUI")!
        defaults.removePersistentDomain(forName: "com.wky.MyCloudDriver.FileFilterUI")
        self.defaults = defaults
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudFileFilterUI")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _hub = StateObject(wrappedValue: CloudDriveHub(
            pikpak: DownloaderModel.browserFileFilterFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
            localRootURL: root))
    }
    var body: some View {
        VStack(spacing: 0) {
            Toggle("Show native Photos fixture", isOn: $nativeView).padding(8)
            if nativeView { NativeDriveWorkspace(model: native, hub: hub, settings: model.finderSettings) }
            else { ContentView().environmentObject(model).environmentObject(model.finderSettings) }
        }.defaultAppStorage(defaults).task { native.connect(FilterTestDrive(kind: .photos)) }
    }
}
