import AppKit
import SwiftUI
import Photos

/// All data is synthetic. This app has no cloud helper or credential access.
@main @MainActor struct BookmarksUITestApp: App {
    @StateObject private var hub: CloudDriveHub
    private let defaults: UserDefaults
    private let bookmarks: FinderBookmarkStore
    private let lifetime: BookmarksFixtureLifetime
    init() {
        let suite = "com.wky.MyCloudDriver.BookmarksUIFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "showsPreviewPane")
        defaults = preferences
        let bookmarkStore = FinderBookmarkStore(defaults: preferences)
        bookmarks = bookmarkStore
        let model = DownloaderModel.finderWorkspaceFixture(defaults: preferences)
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MyCloudDriver-BookmarksUIFixture-\(UUID().uuidString)")
        lifetime = BookmarksFixtureLifetime(directory: directory, suite: suite)
        try! FileManager.default.createDirectory(at: directory.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        try! Data("Synthetic bookmark fixture.\n".utf8).write(to: directory.appendingPathComponent("Folder/Nested/Example.txt"))
        let hub = CloudDriveHub(pikpak: model, defaults: preferences, restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }), localRootURL: directory)
        // Seed only this fixture app's defaults domain, never a real account.
        for item in model.browserTreeEntries.map(\.item).filter({ $0.name == "Drafts" || $0.name == "Design.txt" }) {
            if let bookmark = model.bookmark(item) { bookmarkStore.add(bookmark) }
        }
        for url in [directory.appendingPathComponent("Folder"), directory.appendingPathComponent("Folder/Nested/Example.txt")] {
            if let item = try? ICloudDriveProvider.item(url), let bookmark = hub.local.bookmark(item) { bookmarkStore.add(bookmark) }
        }
        hub.open(.pikpak)
        _hub = StateObject(wrappedValue: hub)
    }
    var body: some Scene {
        Window("MyCloudDriver · Bookmarks Fixture", id: "bookmarks-fixture") {
            MyCloudDriverRootView(hub: hub, settings: hub.pikpak.finderSettings)
                .defaultAppStorage(defaults)
                .environment(\.finderBookmarkStore, bookmarks)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in lifetime.cleanup() }
        }.defaultSize(width: 980, height: 700)
        .commands {
            FinderCommands(settings: hub.pikpak.finderSettings)
            CommandMenu("Fixture") {
                Button("PikPak Browser") { hub.open(.pikpak) }
                Button("PikPak Bookmarks") { hub.open(.pikpak); hub.pikpakNavigation.showImmediately(7) }
                Button("Local Browser") { hub.open(.local) }
                Button("Local Bookmarks") { hub.open(.local); hub.pikpakNavigation.showImmediately(7) }
                Button("Half Screen") { NSApp.keyWindow?.setContentSize(.init(width: 700, height: 820)) }
            }
        }
    }
}

private final class BookmarksFixtureLifetime {
    let directory: URL
    let suite: String
    init(directory: URL, suite: String) { self.directory = directory; self.suite = suite }
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    deinit { cleanup() }
}
