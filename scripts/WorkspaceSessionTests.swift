import AppKit
import Combine
import Foundation

@main struct WorkspaceSessionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try await testCommandRegistrations()
        try await testSearchAfterBrowserClose()
        try testCredentialOwnerRetention()
        try await testSessionLifecycle()
        print("PASS workspace sessions: independent folders, selections, history, sidebars, drive titles and command routing; shared preferences; owner-specific auxiliary recovery and teardown")
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
        var insideTeardown = false, synchronousPublications = 0, deferredPublications = 0
        let observation = FinderCommandRouter.shared.objectWillChange.sink {
            if insideTeardown { synchronousPublications += 1 }
            else { deferredPublications += 1 }
        }
        insideTeardown = true
        bridge.removeFromSuperview()
        insideTeardown = false
        precondition(FinderCommandRouter.shared.actions == nil,
            "Detached views must invalidate their commands immediately")
        precondition(synchronousPublications == 0,
            "SwiftUI view teardown must never synchronously publish routing changes")
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(FinderCommandRouter.shared.actions == nil, "Detaching the view must unregister its commands")
        precondition(deferredPublications == 1, "Routing teardown must publish once after the update pass")
        observation.cancel()
        bridgeWindow.close()
        print("PASS command routing: immediate token-aware invalidation with deferred teardown publication, Home clearing, and stale callback rejection")
    }

    @MainActor static func testSessionLifecycle() async throws {
        let suite = "com.wky.MyCloudDriver.WorkspaceSessionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func makeHub(_ sessionID: String = "primary", settings: FinderSettings? = nil) -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults,
                          workspaceSessionID: sessionID, settings: settings), defaults: defaults,
                          restoreConnections: false, photosAccess: .init(status: { .denied }, request: { .denied },
                          provider: { PhotosDriveProvider() }), localRootURL: root)
        }
        let hub = makeHub()
        var created = 0
        let manager = WorkspaceSessionManager(initialHub: hub, makeHub: { sessionID, settings in
            created += 1; return makeHub(sessionID, settings: settings)
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
        let keys = (1...8).map { PikPakWorkspaceStorage.sessionID(for: $0) }
        let windows = keys.map { manager.windowForTesting($0)! }
        let hubs = keys.map { manager.hubForTesting($0)! }
        precondition(created == 7 && manager.workspaceCount == 8, "Each new window needs its own browsing workspace")
        precondition(Set(hubs.map { ObjectIdentifier($0) }).count == 8)
        precondition(Set(hubs.map { ObjectIdentifier($0.pikpak) }).count == 8)
        precondition(hubs.allSatisfy { $0.pikpak.finderSettings === manager.settings }, "Preferences remain shared")
        let sessions = hubs.dropFirst().map { $0.pikpak.workspaceSessionID }
        precondition(Set(sessions).count == 7 && sessions.allSatisfy { $0.hasPrefix("window-") && PikPakWorkspaceStorage.isValidSessionID($0) },
                     "New workspaces need fresh storage namespaces, independent of reusable AppKit window slots")
        precondition(hub.pikpak.workspaceSessionID == "primary")
        precondition(hubs.allSatisfy { $0.pikpak.transferWorkspaceSessionsToExclude?() == Set(sessions) },
                     "Every model must exclude current-run queues from primary's recovery import")
        precondition(primary.frame == original, "New windows must not rearrange existing windows")
        hubs.forEach { $0.open(.pikpak) }
        precondition(windows.allSatisfy { $0.title.contains("PikPak") && $0.title.contains("Taylor Chen") })
        let secondary = windows[1], secondHub = hubs[1]
        let first = hub.pikpak, second = secondHub.pikpak
        let projects = first.browserItems.first { $0.id == "Projects" }!
        let notes = second.browserItems.first { $0.id == "Notes" }!
        first.openFolder(projects)
        second.openFolder(notes)
        precondition(first.browserStack.map(\.id) == ["", "Projects"])
        precondition(second.browserStack.map(\.id) == ["", "Notes"])
        precondition(first.browserItems.map(\.id) == ["Drafts"] && second.browserItems.isEmpty,
                     "Two windows must browse different remote folder listings simultaneously")
        first.openFolder(first.browserItems[0])
        first.selectBrowserItem(first.browserItems[0])
        precondition(first.browserStack.last?.id == "Drafts" && first.selectedBrowserItemID == "Design.txt")
        precondition(second.browserStack.last?.id == "Notes" && second.selectedBrowserItemID == nil)
        second.goBack()
        second.selectBrowserItem(second.browserItems.first { $0.id == "Readme.txt" }!)
        precondition(second.browserStack.count == 1 && second.selectedBrowserItemID == "Readme.txt")
        precondition(first.browserStack.last?.id == "Drafts" && first.selectedBrowserItemID == "Design.txt",
                     "Back navigation and selection must affect only their owning window")
        first.goBack()
        precondition(first.browserStack.last?.id == "Projects" && first.selectedBrowserItemID == "Drafts",
                     "A window retains its own folder history and restores its previous selection")
        precondition(second.browserStack.count == 1 && second.selectedBrowserItemID == "Readme.txt")
        hub.pikpakNavigation.showImmediately(FinderWorkspaceSection.links.rawValue)
        secondHub.pikpakNavigation.showImmediately(FinderWorkspaceSection.transfers.rawValue)
        precondition(hub.pikpakNavigation.section == FinderWorkspaceSection.links.rawValue
                     && secondHub.pikpakNavigation.section == FinderWorkspaceSection.transfers.rawValue,
                     "Sidebar destinations must be independent")
        manager.settings.showsPreviewPane.toggle()
        precondition(first.finderSettings.showsPreviewPane == second.finderSettings.showsPreviewPane)
        focus(secondary)
        precondition(manager.activeHub === secondHub)
        secondHub.open(.local)
        precondition(secondary.title.contains("Local Disk") && primary.title.contains("PikPak"))
        precondition(hub.selected == .pikpak && secondHub.selected == .local,
                     "Switching drives must update only the owning window and its title")
        precondition(!primary.isExcludedFromWindowsMenu && !secondary.isExcludedFromWindowsMenu)
        let primaryToken = UUID(), secondaryToken = UUID()
        FinderCommandRouter.shared.update(actions(11), window: primary, token: primaryToken)
        FinderCommandRouter.shared.update(actions(22), window: secondary, token: secondaryToken)
        focus(primary)
        precondition(manager.activeHub === hub && FinderCommandRouter.shared.actions?.section == 11)
        focus(secondary)
        precondition(manager.activeHub === secondHub && FinderCommandRouter.shared.actions?.section == 22)
        var firstResourceReads = 0, secondResourceReads = 0
        hub.pikpak.additionalResourceActivities = {
            firstResourceReads += 1
            return [91_001: .init(name: "First scan", processing: .init(backend: .coreml, activeJobs: 2, jobLimit: 2))]
        }
        secondHub.pikpak.additionalResourceActivities = {
            secondResourceReads += 1
            return [91_002: .init(name: "Second scan", processing: .init(backend: .coreml, activeJobs: 1, jobLimit: 2))]
        }
        let activities = manager.resourceActivities
        precondition(activities[91_001]?.processing?.activeJobs == 2 && activities[91_002]?.processing?.activeJobs == 1
                     && firstResourceReads == 1 && secondResourceReads == 1,
                     "Resource reporting includes every workspace exactly once")
        manager.register(primary, hub: hub)
        precondition(manager.workspaceCount == 8, "Repeated view registration is idempotent")
        let unrelated = makeHub()
        manager.register(primary, hub: unrelated)
        precondition(manager.workspaceCount == 8 && manager.hubForTesting("primary") === hub)
        unrelated.pikpak.stopForWindowClose(); unrelated.close()
        let middle = windows[3], closedSessionID = hubs[3].pikpak.workspaceSessionID
        closeNotification(middle)
        manager.register(middle, hub: hubs[3])
        closeNotification(middle)
        precondition(manager.workspaceCount == 7 && manager.tearDownCountForTesting == 1,
                     "Closing an idle workspace tears down only its own model")
        first.openFolder(first.browserItems[0])
        precondition(first.browserStack.last?.id == "Drafts" && second.browserStack.count == 1,
                     "Other windows remain usable after one window closes")
        manager.newWindow()
        let replacement = manager.windowForTesting("workspace-4")!
        let replacementHub = manager.hubForTesting("workspace-4")!
        precondition(replacement !== middle && created == 8 && replacementHub !== hubs[3])
        precondition(replacementHub.pikpak.workspaceSessionID != closedSessionID
                     && replacementHub.pikpak.workspaceSessionID.hasPrefix("window-")
                     && PikPakWorkspaceStorage.isValidSessionID(replacementHub.pikpak.workspaceSessionID),
                     "Reusing a window slot must not reload the closed window's storage")
        precondition(hub.pikpak.transferWorkspaceSessionsToExclude?().contains(closedSessionID) == true
                     && hub.pikpak.transferWorkspaceSessionsToExclude?().contains(replacementHub.pikpak.workspaceSessionID) == true,
                     "Retired current-run queues must remain excluded from another model's recovery import")
        focus(primary)
        closeNotification(primary)
        precondition(manager.workspaceCount == 7 && manager.tearDownCountForTesting == 2)
        manager.newWindow()
        let newPrimary = manager.windowForTesting("primary")!, newPrimaryHub = manager.hubForTesting("primary")!
        precondition(newPrimary !== primary && newPrimaryHub !== hub && created == 9 && manager.workspaceCount == 8,
                     "New Window must still work after the original primary workspace closes")
        precondition(newPrimaryHub.pikpak.workspaceSessionID.hasPrefix("window-")
                     && PikPakWorkspaceStorage.isValidSessionID(newPrimaryHub.pikpak.workspaceSessionID))
        manager.activateBrowser(in: secondHub)
        precondition(manager.workspaceCount == 8 && manager.activeHub === secondHub,
                     "Reveal reuses the browser owned by the requested model")
        let remaining = keys.compactMap { manager.windowForTesting($0) }
        for window in remaining { closeNotification(window) }
        precondition(manager.workspaceCount == 0 && lastCloseCount == 1 && manager.tearDownCountForTesting == 10)
        manager.closeAll(); manager.closeAll(); closeNotification(replacement)
        precondition(manager.tearDownCountForTesting == 10 && lastCloseCount == 1,
                     "Every workspace and final app notification must tear down exactly once")
        for window in windows + [replacement, newPrimary] { window.close() }
        print("PASS independent windows: eight models, separate folders/history/selections/sidebar/drive titles, shared preferences, focused commands and per-workspace lifecycle")
    }

    @MainActor static func testSearchAfterBrowserClose() async throws {
        let suite = "com.wky.MyCloudDriver.SearchRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func makeHub(_ sessionID: String = "primary", settings: FinderSettings? = nil) -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults,
                workspaceSessionID: sessionID, settings: settings), defaults: defaults, restoreConnections: false,
                photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
                localRootURL: root)
        }
        let owner = makeHub()
        let manager = WorkspaceSessionManager(initialHub: owner, makeHub: { id, settings in makeHub(id, settings: settings) })
        manager.presentsWindows = false
        var lastCloseCount = 0
        manager.lastWindowClosedForTesting = { lastCloseCount += 1 }
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
                     "An auxiliary scan keeps only its owning workspace alive")
        manager.newWindow()
        let second = manager.windowForTesting("secondary")!, secondHub = manager.hubForTesting("secondary")!
        precondition(secondHub !== owner && manager.hubForTesting("primary") === owner,
                     "A retained scan must reserve its browser slot when another window opens")
        secondHub.open(.local); focus(second)
        precondition(manager.activeHub === secondHub)
        focus(scan); manager.presentSearch(scope: .root)
        let restored = manager.windowForTesting("primary")!
        precondition(restored !== browser && manager.workspaceCount == 2 && manager.activeHub === owner)
        precondition(owner.selected == .pikpak && owner.pikpak.fileSearch.isPresented && owner.pikpak.fileSearch.scope == .root)
        precondition(secondHub.selected == .local && !secondHub.pikpak.fileSearch.isPresented,
                     "Scan Search must restore the scan owner's browser, preserving the other window")
        owner.pikpak.fileSearch.close()
        owner.open(.local); focus(restored)
        var nativeTarget: CloudDriveHub?
        let observer = NotificationCenter.default.addObserver(forName: .init("MyCloudDriverFind"), object: nil, queue: .main) { note in
            MainActor.assumeIsolated { nativeTarget = note.object as? CloudDriveHub }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        manager.presentSearch(scope: .root)
        precondition(!owner.pikpak.fileSearch.isPresented && nativeTarget == nil)
        manager.presentSearch(scope: .expanded)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(nativeTarget === owner && !owner.pikpak.fileSearch.isPresented)
        nativeTarget = nil; focus(second); manager.presentSearch(scope: .expanded)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(nativeTarget === secondHub, "Native Find also follows the focused workspace")
        owner.pikpak.fileSimilarity.close()
        closeNotification(restored)
        precondition(manager.workspaceCount == 1 && manager.tearDownCountForTesting == 1)
        secondHub.open(.pikpak)
        secondHub.pikpak.openFolder(secondHub.pikpak.browserItems.first { $0.id == "Notes" }!)
        precondition(secondHub.pikpak.browserStack.last?.id == "Notes",
                     "Closing a scan and its restored browser must not stop another workspace")
        closeNotification(second)
        precondition(manager.workspaceCount == 0 && manager.tearDownCountForTesting == 2 && lastCloseCount == 1)
        manager.closeAll(); [browser, restored, second].forEach { $0.close() }
        print("PASS scan search: retained owner recovery, reserved window slot, independent cloud/native scope and safe teardown")
    }

    @MainActor static func testCredentialOwnerRetention() throws {
        let suite = "com.wky.MyCloudDriver.CredentialOwnerRetentionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func makeHub(_ sessionID: String = "primary", settings: FinderSettings? = nil) -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults,
                workspaceSessionID: sessionID, settings: settings), defaults: defaults, restoreConnections: false,
                photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
                localRootURL: root)
        }
        let owner = makeHub()
        let manager = WorkspaceSessionManager(initialHub: owner, makeHub: { id, settings in makeHub(id, settings: settings) })
        manager.presentsWindows = false
        var lastCloseCount = 0
        manager.lastWindowClosedForTesting = { lastCloseCount += 1 }
        var needsOwner = true
        manager.relayAccountNeededForTesting = { needsOwner && $0 === owner.pikpak }
        let primary = makeWindow(); manager.register(primary, hub: owner); focus(primary)
        owner.open(.pikpak)
        owner.pikpak.openFolder(owner.pikpak.browserItems.first { $0.id == "Projects" }!)
        owner.pikpak.selectBrowserItem(owner.pikpak.browserItems[0])
        manager.newWindow()
        let second = manager.windowForTesting("secondary")!, secondHub = manager.hubForTesting("secondary")!
        closeNotification(primary)
        precondition(manager.workspaceCount == 1 && manager.tearDownCountForTesting == 0
                     && manager.hubForTesting("primary") === owner && manager.windowForTesting("primary") == nil,
                     "An active relay's closed credential owner must retain its workspace and browser slot")
        precondition(owner.pikpak.canProvidePikPakRelayContext,
                     "Retaining a credential owner must keep its account context available")
        manager.activateBrowser(in: owner)
        let restored = manager.windowForTesting("primary")!
        precondition(restored !== primary && manager.workspaceCount == 2 && manager.activeHub === owner)
        precondition(manager.hubForTesting("primary") === owner && owner.pikpak.browserStack.last?.id == "Projects"
                     && owner.pikpak.selectedBrowserItemID == "Drafts",
                     "Reveal must recover the exact credential owner's folder and selection")
        needsOwner = false
        closeNotification(restored)
        precondition(manager.workspaceCount == 1 && manager.tearDownCountForTesting == 1
                     && manager.hubForTesting("primary") == nil && !owner.pikpak.canProvidePikPakRelayContext,
                     "The owner can retire after the relay no longer needs its credentials")
        focus(second)
        secondHub.pikpak.openFolder(secondHub.pikpak.browserItems.first { $0.id == "Notes" }!)
        precondition(secondHub.pikpak.canProvidePikPakRelayContext && secondHub.pikpak.browserStack.last?.id == "Notes",
                     "Retiring one credential owner must leave the other browser and account usable")
        closeNotification(second)
        precondition(manager.workspaceCount == 0 && manager.tearDownCountForTesting == 2 && lastCloseCount == 1)
        manager.closeAll(); manager.closeAll()
        precondition(manager.tearDownCountForTesting == 2 && lastCloseCount == 1)
        [primary, restored, second].forEach { $0.close() }
        print("PASS credential owner lifecycle: retained account context, owner-specific browser recovery, reserved slot and isolated retirement")
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
