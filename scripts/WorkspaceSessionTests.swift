import AppKit
import Combine
import Foundation

@main struct WorkspaceSessionTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try await testCommandRegistrations()
        try await testCommandMenuTracking()
        try await testCommandPresentationUpdates()
        try await testSearchAfterBrowserClose()
        try testCredentialOwnerRetention()
        try await testSessionLifecycle()
        print("PASS workspace sessions: independent folders, selections, history, sidebars, drive titles and command routing; shared preferences; owner-specific auxiliary recovery and teardown")
    }

    @MainActor static func testCommandPresentationUpdates() async throws {
        let center = NotificationCenter(), router = FinderCommandRouter(notificationCenter: center)
        let first = makeWindow(), second = makeWindow(), token = UUID()
        defer { first.close(); second.close() }
        center.post(name: NSWindow.didBecomeKeyNotification, object: first)
        router.update(actions(1), window: first, token: token)
        try await Task.sleep(nanoseconds: 40_000_000)
        var publications = 0, invoked = 0
        let observation = router.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for value in 1...100 {
            var next = actions(1)
            next.refresh = { invoked = value }
            router.update(next, window: first, token: token)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        router.actions?.refresh()
        precondition(publications == 0 && invoked == 100,
            "Status/progress updates must retain current closures without invalidating command presentation")
        var changed = actions(1); changed.zoom = 1.8; changed.canTrash = true; changed.undoTitle = "Undo generated change"
        router.update(changed, window: first, token: token)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(publications == 1, "Visible command validation must still refresh")
        router.update(actions(2), window: second, token: token)
        center.post(name: NSWindow.didBecomeKeyNotification, object: second)
        precondition(router.actions?.section == 2, "Native focus must route commands without a FocusedValue subscription")
        print("PASS command presentation: 100 background updates produce no invalidations; fresh callbacks, validation changes and native window routing remain current")
    }

    @MainActor static func testCommandMenuTracking() async throws {
        let center = NotificationCenter(), router = FinderCommandRouter(notificationCenter: center)
        let window = makeWindow(), token = UUID()
        defer { window.close() }
        let parent = NSMenu(title: "View"), child = NSMenu(title: "Preview Placement")
        var publications = 0, invoked = 0
        let observation = router.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        router.focus(window)
        router.update(actions(1), window: window, token: token)
        // Tracking may begin after an update was queued but before it publishes.
        center.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        center.post(name: NSMenu.didBeginTrackingNotification, object: child)
        for value in 2...30 {
            var next = actions(value)
            next.refresh = { invoked = value }
            router.update(next, window: window, token: token)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(publications == 0, "Background updates must not rebuild a tracked submenu")
        router.actions?.refresh()
        precondition(invoked == 30 && router.actions?.section == 30,
            "Menu action dispatch must use the latest registration while presentation is deferred")
        center.post(name: NSMenu.didEndTrackingNotification, object: child)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(publications == 0, "Closing a submenu must not rebuild its still-open parent")
        center.post(name: NSMenu.didEndTrackingNotification, object: parent)
        precondition(publications == 0, "Menu-close notifications must publish outside AppKit tracking")
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(publications == 1, "Closing the full menu must publish the latest state once")
        center.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        router.close(window)
        precondition(router.actions == nil, "Closing a window must invalidate actions even while a menu is open")
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(publications == 1)
        center.post(name: NSMenu.didEndTrackingNotification, object: parent)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(publications == 2, "Cancelled tracking must also release pending command validation")
        print("PASS menu tracking: background command updates coalesce until all menus close; live actions and immediate closed-window invalidation remain current")
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
        let searchCommands = FinderSearchCommandState(sessions: manager)
        var searchPublications = 0
        let searchObservation = searchCommands.objectWillChange.sink { searchPublications += 1 }
        defer { searchObservation.cancel() }
        for value in 1...100 { owner.pikpak.status = "Generated status \(value)" }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(searchPublications == 0, "Transfer status must not invalidate search or View menus")
        manager.presentSearch(scope: .expanded)
        precondition(!owner.pikpak.fileSearch.isPresented)
        owner.open(.local)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(searchCommands.snapshot.drive == .local && searchPublications == 1)
        owner.pikpak.isLoginPresented = true
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(searchCommands.snapshot.isLoginPresented && searchPublications == 2)
        owner.pikpak.isLoginPresented = false
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(!searchCommands.snapshot.isLoginPresented && searchPublications == 3,
            "Search validation must follow drive and login changes after unrelated updates are removed")
        owner.pikpak.fileSimilarity.presentDrive("pikpak")
        let scan = owner.pikpak.fileSimilarity.presentedWindow!
        scan.orderOut(nil); focus(scan)
        precondition(manager.searchDrive == .pikpak)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(searchCommands.snapshot.drive == .pikpak)
        focus(browser)
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(searchCommands.snapshot.drive == .local,
            "Search validation must follow browser/scan focus changes within the same hub")
        focus(scan)
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
        manager.presentSearch(scope: .root)
        precondition(owner.local.fileSearch.isPresented && owner.local.fileSearch.scope == .root
                     && !owner.pikpak.fileSearch.isPresented && !secondHub.local.fileSearch.isPresented,
                     "Native root Find must open the current owner's search palette")
        owner.local.fileSearch.close()
        manager.presentSearch(scope: .expanded)
        precondition(owner.local.fileSearch.isPresented && owner.local.fileSearch.scope == .expanded
                     && !owner.pikpak.fileSearch.isPresented && !secondHub.local.fileSearch.isPresented)
        focus(second); manager.presentSearch(scope: .expanded)
        precondition(secondHub.local.fileSearch.isPresented && secondHub.local.fileSearch.scope == .expanded
                     && owner.local.fileSearch.isPresented, "Native Find also follows the focused workspace")
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
