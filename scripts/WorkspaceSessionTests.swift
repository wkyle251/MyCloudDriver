import AppKit
import Foundation

@main struct WorkspaceSessionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try await testCommandRegistrations()
        try await testSearchAfterBrowserClose()
        try await testSessionLifecycle()
        print("PASS workspace sessions: shared account and transfers, independent command routing, auxiliary focus, idempotent close and stale-registration protection")
    }

    @MainActor static func testCommandRegistrations() async throws {
        let router = FinderCommandRouter()
        let window = makeWindow()
        defer { window.close() }
        let old = UUID(), current = UUID()
        router.focus(window)
        router.update(actions(1), window: window, token: old)
        router.update(actions(2), window: window, token: current)
        router.unregister(window, token: old)
        precondition(router.actions?.section == 2, "Old view teardown must not erase newer actions")
        router.unregister(window, token: current)
        precondition(router.actions == nil, "Home must not retain the old drive's file commands")
        let other = makeWindow(), otherToken = UUID()
        router.update(actions(20), window: other, token: otherToken)
        router.focus(other)
        router.update(actions(30), window: window, token: current)
        precondition(router.actions?.section == 20, "Background workspace updates must not redirect focused commands")
        router.close(other); other.close()
        router.focus(window)
        router.update(actions(3), window: window, token: current)
        router.close(window)
        router.update(actions(4), window: window, token: old)
        router.focus(window)
        precondition(router.actions == nil, "Late callbacks must not restore closed-window actions")

        let bridgeWindow = makeWindow()
        let bridge = FinderWindowActionRegistration.ViewBridge()
        bridgeWindow.contentView?.addSubview(bridge)
        bridge.actions = actions(10)
        bridge.register()
        bridge.unregister()
        try await Task.sleep(nanoseconds: 40_000_000)
        FinderCommandRouter.shared.focus(bridgeWindow)
        precondition(FinderCommandRouter.shared.actions == nil, "Dismantle must invalidate a queued registration")
        bridge.register()
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(FinderCommandRouter.shared.actions?.section == 10)
        bridge.removeFromSuperview()
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(FinderCommandRouter.shared.actions == nil, "Detaching the view must unregister its commands")
        bridgeWindow.close()
        print("PASS command routing: token-aware teardown, Home clearing, and invalidated deferred callbacks")
    }

    @MainActor static func testSessionLifecycle() async throws {
        let suite = "com.wky.MyCloudDriver.WorkspaceSessionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func makeHub() -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
                          restoreConnections: false, photosAccess: .init(status: { .denied }, request: { .denied },
                          provider: { PhotosDriveProvider() }), localRootURL: root)
        }
        let hub = makeHub()
        var created = 0
        let manager = WorkspaceSessionManager(initialHub: hub, makeHub: { _, _ in
            created += 1; return makeHub()
        })
        manager.presentsWindows = false
        var lastCloseCount = 0
        manager.lastWindowClosedForTesting = { lastCloseCount += 1 }
        let primary = makeWindow()
        manager.register(primary, hub: hub)
        precondition(manager.workspaceCount == 1 && manager.canPresentSimilarity)
        precondition(hub.similarityEntryDrive == .local)
        hub.open(.pikpak)
        let original = primary.frame
        for _ in 2...8 { manager.newWindow() }
        let windows = (1...8).map { manager.windowForTesting(PikPakWorkspaceStorage.sessionID(for: $0))! }
        precondition(created == 0 && manager.workspaceCount == 8, "New windows must never create accounts, queues or providers")
        precondition(primary.frame == original, "New windows must not rearrange existing windows")
        precondition(windows.allSatisfy { $0.title.contains("PikPak") && $0.title.contains("Taylor Chen") })
        precondition(hub.pikpak.workspaceSessionID == "primary", "Window identifiers must not become storage namespaces")
        let secondary = windows[1]
        focus(secondary)
        precondition(manager.activeHub === hub)
        hub.open(.local)
        precondition(windows.allSatisfy { $0.title.contains("Local Disk") }, "Drive state is shared by every window")
        precondition(!primary.isExcludedFromWindowsMenu && !secondary.isExcludedFromWindowsMenu)
        var resourceReads = 0
        hub.pikpak.additionalResourceActivities = {
            resourceReads += 1
            return [91_001: .init(name: "Shared scan", processing: .init(backend: .coreml, activeJobs: 2, jobLimit: 2))]
        }
        precondition(manager.resourceActivities[91_001]?.processing?.activeJobs == 2 && resourceReads == 1,
                     "One scan must not be counted once per window")
        manager.register(primary, hub: hub)
        precondition(manager.workspaceCount == 8, "Repeated view registration is idempotent")
        let unrelated = makeHub()
        manager.register(primary, hub: unrelated)
        precondition(manager.workspaceCount == 8 && manager.windowForTesting("primary") === primary)
        unrelated.close()
        let middle = windows[3]
        closeNotification(middle)
        manager.register(middle, hub: hub)
        closeNotification(middle)
        precondition(manager.workspaceCount == 7 && manager.tearDownCountForTesting == 0,
                     "Closing one window must leave shared transfers and scans alive")
        manager.newWindow()
        let replacement = manager.windowForTesting("workspace-4")!
        precondition(replacement !== middle && created == 0 && hub.selected == .local)
        focus(primary)
        closeNotification(primary)
        precondition(manager.workspaceCount == 7 && manager.tearDownCountForTesting == 0)
        manager.activateBrowser(in: hub)
        precondition(manager.workspaceCount == 7 && manager.activeHub === hub,
                     "Reveal reuses another open browser without creating a session")
        let remaining = (1...8).compactMap { manager.windowForTesting(PikPakWorkspaceStorage.sessionID(for: $0)) }
        for window in remaining { closeNotification(window) }
        precondition(manager.workspaceCount == 0 && lastCloseCount == 1 && manager.tearDownCountForTesting == 1)
        manager.closeAll(); manager.closeAll(); closeNotification(replacement)
        precondition(manager.tearDownCountForTesting == 1 && lastCloseCount == 1, "Final teardown must happen exactly once")
        for window in windows + [replacement] { window.close() }
        print("PASS shared windows: eight views, one session, shared navigation, deduplicated resources, retained work and one final teardown")
    }

    @MainActor static func testSearchAfterBrowserClose() async throws {
        let suite = "com.wky.MyCloudDriver.SearchRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let owner = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults),
            defaults: defaults, restoreConnections: false, localRootURL: root)
        let manager = WorkspaceSessionManager(initialHub: owner)
        manager.presentsWindows = false; manager.lastWindowClosedForTesting = {}
        let browser = makeWindow(); manager.register(browser, hub: owner); focus(browser)
        precondition(manager.searchDrive == nil)
        manager.presentSearch(scope: .expanded)
        precondition(!owner.pikpak.fileSearch.isPresented)
        owner.open(.local)
        owner.pikpak.fileSimilarity.presentDrive("pikpak")
        let scan = owner.pikpak.fileSimilarity.presentedWindow!
        scan.orderOut(nil); focus(scan)
        precondition(manager.searchDrive == .pikpak)
        browser.close()
        precondition(manager.workspaceCount == 0 && manager.tearDownCountForTesting == 0,
                     "A remaining scan window keeps the shared session alive")
        manager.presentSearch(scope: .expanded)
        let restored = manager.windowForTesting("primary")!
        precondition(restored !== browser && manager.workspaceCount == 1 && manager.activeHub === owner)
        precondition(owner.selected == .pikpak && owner.pikpak.fileSearch.isPresented && owner.pikpak.fileSearch.scope == .expanded)
        owner.pikpak.fileSearch.close()
        manager.newWindow()
        let second = manager.windowForTesting("secondary")!
        owner.open(.local); focus(second)
        focus(scan); manager.presentSearch(scope: .root)
        precondition(manager.workspaceCount == 2 && owner.pikpak.fileSearch.isPresented && owner.pikpak.fileSearch.scope == .root,
                     "Scan search uses an existing shared browser")
        owner.pikpak.fileSearch.close()
        owner.open(.local)
        var nativeTarget: CloudDriveHub?
        let observer = NotificationCenter.default.addObserver(forName: .init("MyCloudDriverFind"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated { nativeTarget = note.object as? CloudDriveHub }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        manager.presentSearch(scope: .root)
        precondition(!owner.pikpak.fileSearch.isPresented)
        manager.presentSearch(scope: .expanded)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(nativeTarget === owner && !owner.pikpak.fileSearch.isPresented)
        manager.closeAll(); [browser, restored, second].forEach { $0.close() }
        print("PASS scan search: shared browser recovery, existing-window reuse and correct cloud/native scope")
    }

    @MainActor static func focus(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }
    @MainActor static func closeNotification(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    }
    @MainActor static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 180, y: 160, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    static func actions(_ section: Int) -> FinderWindowActions {
        FinderWindowActions(section: section, viewMode: 0, zoom: 1, undoTitle: "Undo", redoTitle: "Redo", canUndo: false, canRedo: false,
            undo: {}, redo: {}, canRefresh: true, canGoBack: true, canUpload: true, canDownload: true, canCreateFolder: true, canTrash: true,
            canCheckDuplicates: true, canReviewDuplicates: false, canRemoveEmptyFolders: true, canRemoveDSStoreFiles: true, canMergeFolders: true,
            checkDuplicates: {}, findSimilarFiles: {}, reviewDuplicates: {}, removeEmptyFolders: {}, removeDSStoreFiles: {}, mergeFolders: {},
            showStatus: {}, selectSection: { _ in }, setViewMode: { _ in }, adjustZoom: { _ in }, resetZoom: {}, refresh: {}, goBack: {},
            upload: {}, download: {}, newFolder: {}, trash: {})
    }
}
