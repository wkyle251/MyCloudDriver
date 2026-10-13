import AppKit
import Combine
import SwiftUI

/// Commands from SwiftUI's main scene also target the independently hosted
/// workspace windows. A window registration avoids broadcasting actions.
@MainActor final class FinderCommandRouter: ObservableObject {
    static let shared = FinderCommandRouter()
    @Published private(set) var actions: FinderWindowActions?
    private struct Entry { let token: UUID; let actions: FinderWindowActions }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private weak var focusedWindow: NSWindow?
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()
    func update(_ actions: FinderWindowActions, window: NSWindow, token: UUID) {
        guard !closedWindows.contains(window) else { return }
        entries[ObjectIdentifier(window)] = Entry(token: token, actions: actions)
        if window.isKeyWindow || focusedWindow === window {
            focusedWindow = window; self.actions = actions
        }
    }
    func focus(_ window: NSWindow) { focusedWindow = window; actions = entries[ObjectIdentifier(window)]?.actions }
    func unregister(_ window: NSWindow, token: UUID) {
        guard entries[ObjectIdentifier(window)]?.token == token else { return }
        remove(window)
    }
    func remove(_ window: NSWindow) {
        entries[ObjectIdentifier(window)] = nil
        if focusedWindow === window { actions = nil }
    }
    func close(_ window: NSWindow) {
        closedWindows.add(window); remove(window)
        if focusedWindow === window { focusedWindow = nil }
    }
}

struct FinderWindowActionRegistration: NSViewRepresentable {
    let actions: FinderWindowActions
    func makeNSView(context: Context) -> ViewBridge { ViewBridge() }
    func updateNSView(_ view: ViewBridge, context: Context) { view.actions = actions; view.register() }
    static func dismantleNSView(_ view: ViewBridge, coordinator: ()) { view.unregister() }
    final class ViewBridge: NSView {
        var actions: FinderWindowActions?
        private let token = UUID()
        private var generation = UUID()
        private weak var registeredWindow: NSWindow?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            generation = UUID()
            if registeredWindow !== window { unregister() }
            guard let window, let actions else { return }
            let generation = generation
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.generation == generation else { return }
                self.registeredWindow = window
                FinderCommandRouter.shared.update(actions, window: window, token: self.token)
            }
        }
        func unregister() {
            generation = UUID()
            if let registeredWindow { FinderCommandRouter.shared.unregister(registeredWindow, token: token) }
            registeredWindow = nil
        }
    }
}

@MainActor final class WorkspaceSessionManager: ObservableObject {
    static weak var current: WorkspaceSessionManager?
    let initialHub: CloudDriveHub
    let settings: FinderSettings
    private let makeHub: (String, FinderSettings) -> CloudDriveHub
    private var currentRunStorageSessions = Set<String>()
    @Published private(set) var activeHub: CloudDriveHub
    @Published private(set) var workspaceCount = 0
    private struct Entry {
        let hub: CloudDriveHub
        weak var window: NSWindow?
        var controller: NSWindowController?
        var titleObservation: AnyCancellable?
    }
    private var entries: [String: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()
    private let tornDownHubs = NSHashTable<CloudDriveHub>.weakObjects()
    private var closingAll = false
    private var didFinishAllWindows = false
    private weak var focusedWindow: NSWindow?
    #if FINDER_WORKSPACE_TESTS
    var presentsWindows = true
    var lastWindowClosedForTesting: (() -> Void)?
    var relayAccountNeededForTesting: ((DownloaderModel) -> Bool)?
    private(set) var tearDownCountForTesting = 0
    func windowForTesting(_ id: String) -> NSWindow? { entries[id]?.window }
    func hubForTesting(_ id: String) -> CloudDriveHub? { entries[id]?.hub }
    #endif
    private var shouldPresentWindows: Bool {
        #if FINDER_WORKSPACE_TESTS
        return presentsWindows
        #else
        return true
        #endif
    }

    init(initialHub: CloudDriveHub? = nil, makeHub: ((String, FinderSettings) -> CloudDriveHub)? = nil) {
        let settings = initialHub?.pikpak.finderSettings ?? FinderSettings()
        self.settings = settings
        let factory = makeHub ?? { id, settings in CloudDriveHub(pikpak: DownloaderModel(workspaceSessionID: id, settings: settings)) }
        self.makeHub = factory
        let hub = initialHub ?? factory("primary", settings)
        self.initialHub = hub; activeHub = hub
        configureTransferImports(in: hub)
        Self.current = self
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { self?.focus(window) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { self?.closed(window) } }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    private func configureTransferImports(in hub: CloudDriveHub) {
        hub.pikpak.transferWorkspaceSessionsToExclude = { [weak self] in self?.currentRunStorageSessions ?? [] }
        #if !FINDER_WORKSPACE_TESTS
        LocalTorrentModel.shared.configureRelayAccount(hub.pikpak)
        #endif
    }
    private var managedHubs: [CloudDriveHub] {
        var seen = Set<ObjectIdentifier>()
        return ([initialHub] + entries.values.map(\.hub)).filter {
            !tornDownHubs.contains($0) && seen.insert(ObjectIdentifier($0)).inserted
        }
    }
    private func similarityCoordinators(in hub: CloudDriveHub) -> [FileSimilarityCoordinator] {
        [hub.pikpak.fileSimilarity] + hub.nativeDrives.map(\.similarity)
    }
    private func similarityWindows(in hub: CloudDriveHub) -> [NSWindow] {
        similarityCoordinators(in: hub).compactMap(\.presentedWindow)
    }
    private func updateWorkspaceCount() { workspaceCount = entries.values.filter { $0.window != nil }.count }
    var canPresentSimilarity: Bool { entries.values.contains { $0.hub === activeHub } }
    func presentSimilarity() {
        guard canPresentSimilarity else { return }
        activeHub.presentSimilarity()
    }
    var searchDrive: CloudDriveKind? {
        guard entries.values.contains(where: { $0.hub === activeHub }) else { return nil }
        if let window = focusedWindow,
           let scan = similarityCoordinators(in: activeHub).first(where: { $0.presentedWindow === window }) {
            return CloudDriveKind(rawValue: scan.selectedDriveID)
        }
        return activeHub.selected
    }
    func presentSearch(scope: FileSearchScope) {
        guard let drive = searchDrive, !activeHub.pikpak.isLoginPresented,
              NSApp.keyWindow?.isSheet != true, scope != .root || drive == .pikpak else { return }
        let owner = activeHub
        owner.showCurrentDrive(drive)
        // A scan can outlive its browser. Search must restore and raise the
        // owning browser instead of presenting an overlay in a closed view.
        activateBrowser(in: owner)
        if drive == .pikpak { owner.pikpak.presentFileSearch(scope: scope) }
        else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("MyCloudDriverFind"), object: owner)
            }
        }
    }
    var resourceActivities: [Int32: TaskResourceActivity] {
        var activities: [Int32: TaskResourceActivity] = [:]
        var appDetails: [String] = []
        for hub in managedHubs {
            for (pid, activity) in hub.pikpak.resourceActivities {
                if pid == getpid() { appDetails.append(activity.detail) }
                else { activities[pid] = activity }
            }
        }
        var seen = Set<String>()
        let detail = appDetails.flatMap { $0.components(separatedBy: "\n") }.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        activities[getpid()] = .init(name: "MyCloudDriver", detail: detail, symbol: "macwindow")
        return activities
    }
    func register(_ window: NSWindow, hub: CloudDriveHub) {
        guard !closedWindows.contains(window) else { return }
        if let owner = entries.values.first(where: { $0.window === window }), owner.hub !== hub { return }
        guard !tornDownHubs.contains(hub), hub === initialHub || entries.values.contains(where: { $0.hub === hub }) else { reject(window); return }
        // A browser model belongs to one window. A delayed scene registration
        // must not attach an existing workspace to another browser window.
        guard !entries.values.contains(where: { $0.hub === hub && $0.window != nil && $0.window !== window }) else { reject(window); return }
        let id: String
        if let existing = entries.first(where: { $0.value.window === window }) { id = existing.key }
        else { id = nextWindowID() }
        if entries[id]?.window !== window {
            entries[id] = Entry(hub: hub, window: window, controller: entries[id]?.controller)
            updateWorkspaceCount()
        }
        for coordinator in similarityCoordinators(in: hub) {
            coordinator.onWindowClosed = { [weak self, weak hub] in
                guard let self, let hub else { return }
                self.retireIfNoWindows(hub)
                // A paused helper keeps its workspace busy, so retirement can
                // defer. Closing the final window must still save and stop it.
                self.finishIfNoWindows()
            }
        }
        window.identifier = NSUserInterfaceItemIdentifier("MyCloudDriver.workspace.\(id)")
        window.tabbingMode = .disallowed
        window.isExcludedFromWindowsMenu = false
        if entries[id]?.titleObservation == nil {
            entries[id]?.titleObservation = hub.$selected.combineLatest(hub.pikpak.$accountProfile, hub.$selectedExternalDisk)
                .map { kind, profile, disk in
                    let drive = kind == .local ? disk?.name ?? CloudDriveKind.local.title : kind?.title ?? "All Drives"
                    let account = kind == .pikpak ? profile?.displayName.map { " · \($0)" } ?? "" : ""
                    return "\(drive)\(account) — MyCloudDriver"
                }
                .removeDuplicates()
                .sink { [weak window] title in
                    guard let window else { return }
                    window.title = title
                    NSApp.changeWindowsItem(window, title: title, filename: false)
                }
            // SwiftUI's initial single-window scene excludes itself by default.
            // Include it alongside every independently hosted workspace.
            NSApp.addWindowsItem(window, title: window.title, filename: false)
        }
        if window.isKeyWindow { focus(window) }
    }
    private func reject(_ window: NSWindow) {
        closedWindows.add(window)
        NSApp.removeWindowsItem(window)
        FinderCommandRouter.shared.close(window)
        window.close()
    }
    private func focus(_ window: NSWindow) {
        focusedWindow = window
        if let entry = entries.values.first(where: { $0.window === window || similarityWindows(in: $0.hub).contains(where: { $0 === window }) }) { activeHub = entry.hub }
        FinderCommandRouter.shared.focus(window)
    }
    func newWindow() {
        guard !closingAll, !didFinishAllWindows, let source = managedHubs.first(where: { $0 === activeHub }) ?? managedHubs.first else { return }
        let anchor = entries.values.first(where: { $0.window === focusedWindow })?.window
            ?? entries.values.compactMap(\.window).first
        // AppKit slots may be reused, but persisted queues must never reuse a
        // namespace already imported by the primary workspace on this launch.
        let storageID = PikPakWorkspaceStorage.newSessionID()
        currentRunStorageSessions.insert(storageID)
        let hub = makeHub(storageID, settings)
        configureTransferImports(in: hub)
        hub.pikpak.inheritWindowAccount(from: source.pikpak)
        if source.selected == .local {
            hub.inheritLocalBrowser(from: source)
            hub.selected = .local
        } else if let drive = source.selected { hub.open(drive) }
        openBrowser(hub: hub, id: nextWindowID(), anchor: anchor)
    }
    private func nextWindowID() -> String {
        // A closed browser retained for its work or scan still owns its slot.
        let occupied = Set(entries.keys)
        var slot = 1
        while occupied.contains(PikPakWorkspaceStorage.sessionID(for: slot)) { slot += 1 }
        return PikPakWorkspaceStorage.sessionID(for: slot)
    }
    private func openBrowser(hub: CloudDriveHub, id: String, anchor: NSWindow? = nil) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1240, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: WorkspaceSessionRoot(hub: hub, manager: self))
        window.setContentSize(.init(width: 1240, height: 900))
        window.contentMinSize = .init(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        entries[id] = Entry(hub: hub, window: window, controller: controller)
        register(window, hub: hub)
        updateWorkspaceCount()
        window.center()
        if let anchor {
            window.cascadeTopLeft(from: .init(x: anchor.frame.minX, y: anchor.frame.maxY))
        }
        window.setFrame(window.constrainFrameRect(window.frame, to: anchor?.screen ?? NSScreen.main), display: false)
        if shouldPresentWindows { window.makeKeyAndOrderFront(nil) }
    }
    func revealBrowser(for model: DownloaderModel) {
        guard let entry = entries.values.first(where: { $0.hub.pikpak === model }) else { return }
        entry.hub.open(.pikpak)
        activateBrowser(in: entry.hub)
    }
    /// Restore the browser belonging to this workspace when only its work or
    /// an auxiliary window remains. Never reveal another workspace's folder.
    func activateBrowser(in hub: CloudDriveHub) {
        guard !tornDownHubs.contains(hub) else { return }
        let available = entries.filter { $0.value.hub === hub }
        guard let entry = available.first(where: { $0.value.window != nil && $0.value.window === focusedWindow })
            ?? available.sorted(by: { $0.key < $1.key }).first(where: { $0.value.window != nil })
            ?? available.first else { return }
        if entry.value.window == nil { openBrowser(hub: hub, id: entry.key, anchor: similarityWindows(in: hub).first) }
        guard let window = entries[entry.key]?.window else { return }
        if shouldPresentWindows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        focus(window)
    }
    private func closed(_ window: NSWindow) {
        if focusedWindow === window { focusedWindow = nil }
        FinderCommandRouter.shared.close(window)
        guard let match = entries.first(where: { $0.value.window === window }) else { return }
        closedWindows.add(window)
        NSApp.removeWindowsItem(window)
        entries[match.key]?.window = nil
        entries[match.key]?.controller = nil
        entries[match.key]?.titleObservation = nil
        updateWorkspaceCount()
        retireIfNoWindows(match.value.hub)
        if activeHub === match.value.hub, let available = entries.values.first(where: { $0.window != nil }) { activeHub = available.hub }
        finishIfNoWindows()
    }
    private func retireIfNoWindows(_ hub: CloudDriveHub) {
        guard !closingAll, !tornDownHubs.contains(hub),
              !entries.values.contains(where: { $0.hub === hub && $0.window != nil }),
              similarityWindows(in: hub).isEmpty else { return }
        guard !hub.pikpak.keepsWorkspaceAlive, !hub.nativeDrives.contains(where: { $0.isBusy }),
              !needsRelayAccount(in: hub) else { return }
        entries = entries.filter { $0.value.hub !== hub }
        tearDown(hub)
        updateWorkspaceCount()
        finishIfNoWindows()
    }
    private func needsRelayAccount(in hub: CloudDriveHub) -> Bool {
        #if FINDER_WORKSPACE_TESTS
        return relayAccountNeededForTesting?(hub.pikpak) ?? false
        #else
        return LocalTorrentModel.shared.needsRelayAccount(hub.pikpak)
        #endif
    }
    private func finishIfNoWindows() {
        guard !closingAll, !didFinishAllWindows, !entries.values.contains(where: { $0.window != nil }),
              managedHubs.allSatisfy({ similarityWindows(in: $0).isEmpty }) else { return }
        didFinishAllWindows = true
        #if FINDER_WORKSPACE_TESTS
        closeAll()
        entries.removeAll()
        updateWorkspaceCount()
        if let lastWindowClosedForTesting { lastWindowClosedForTesting(); return }
        #endif
        // AppDelegate must drain download RAM before closeAll terminates helpers.
        NSApp.terminate(nil)
    }
    private func tearDown(_ hub: CloudDriveHub) {
        guard !tornDownHubs.contains(hub) else { return }
        tornDownHubs.add(hub)
        #if FINDER_WORKSPACE_TESTS
        tearDownCountForTesting += 1
        #endif
        hub.pikpak.stopForWindowClose(); hub.pikpak.fileSearch.close(); hub.close()
    }
    func closeAll() {
        // Teardown can close auxiliary windows and post nested AppKit events.
        // Snapshot the hubs before any event can change the registry.
        closingAll = true
        defer { closingAll = false }
        for hub in managedHubs { tearDown(hub) }
    }
    func prepareDownloadsForApplicationTermination() async -> Bool {
        let hubs = managedHubs
        return await withTaskGroup(of: Bool.self) { group in
            for hub in hubs { group.addTask { await hub.pikpak.prepareDownloadsForApplicationTermination() } }
            var saved = true
            for await result in group { saved = result && saved }
            return saved
        }
    }
}

struct WorkspaceSessionRoot: View {
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject var manager: WorkspaceSessionManager
    var body: some View {
        MyCloudDriverRootView(hub: hub, settings: manager.settings)
            .background(WorkspaceWindowRegistration(hub: hub, manager: manager))
            #if !FINDER_WORKSPACE_TESTS
            .background(LocalTorrentLaunchRestoration(account: hub.pikpak))
            #endif
    }
}

private struct WorkspaceWindowRegistration: NSViewRepresentable {
    let hub: CloudDriveHub
    let manager: WorkspaceSessionManager
    func makeNSView(context: Context) -> Bridge { Bridge() }
    func updateNSView(_ view: Bridge, context: Context) {
        view.attach = { [weak manager, weak hub] window in
            guard let manager, let hub else { return }; manager.register(window, hub: hub)
        }
        view.register()
    }
    static func dismantleNSView(_ view: Bridge, coordinator: ()) { view.unregister() }
    final class Bridge: NSView {
        var attach: ((NSWindow) -> Void)?
        private var generation = UUID()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            generation = UUID()
            guard let window, let attach else { return }
            let generation = generation
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.generation == generation else { return }
                attach(window)
            }
        }
        func unregister() { generation = UUID(); attach = nil }
    }
}
