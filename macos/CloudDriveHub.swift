import AppKit
import SwiftUI
@preconcurrency import Photos

struct DriveConnectionFeedback {
    let message: String
    var isError = false
}

@MainActor final class CloudDriveHub: ObservableObject {
    @Published var selected: CloudDriveKind?
    @Published var connectionError: String?
    @Published private(set) var connectingPhotos = false
    @Published private(set) var photosAuthorization: PHAuthorizationStatus
    @Published private(set) var photosFeedback: DriveConnectionFeedback?
    @Published private(set) var photosLastChecked: Date?
    let pikpak: DownloaderModel
    let pikpakNavigation = FinderWorkspaceNavigation()
    let icloud: NativeDriveModel
    let photos: NativeDriveModel
    let local: NativeDriveModel
    var nativeDrives: [NativeDriveModel] { [icloud, photos, local] }
    let icloudStorage: ICloudStorageModel
    private let defaults: UserDefaults
    private let photosAccess: PhotosAccessClient
    private var photosConnectionTask: Task<Void, Never>?
    private var photosConnectionID = UUID()
    private static let photosDisconnectedKey = "myCloudDriver.photosDisconnected"
    private var scopedICloudURL: URL?
    private var scopedLocalURL: URL?
    init(pikpak: DownloaderModel, defaults: UserDefaults = .standard, restoreConnections: Bool = true,
         photosAccess: PhotosAccessClient? = nil, icloudStorage: ICloudStorageModel? = nil, localRootURL: URL? = nil) {
        let photosAccess = photosAccess ?? .system
        self.pikpak = pikpak; self.defaults = defaults; self.photosAccess = photosAccess
        icloud = NativeDriveModel(kind: .icloud, playbackSettings: pikpak.finderSettings.playback)
        photos = NativeDriveModel(kind: .photos, playbackSettings: pikpak.finderSettings.playback)
        local = NativeDriveModel(kind: .local, playbackSettings: pikpak.finderSettings.playback)
        self.photosAuthorization = photosAccess.status()
        self.icloudStorage = icloudStorage ?? ICloudStorageModel()
        for drive in [icloud, photos, local] {
            let name = drive.kind.rawValue
            drive.scanConfiguration = { [weak pikpak] in
                guard let pikpak else { throw CocoaError(.userCancelled) }
                return try pikpak.nativeSimilarityConfiguration(drive: name)
            }
        }
        pikpak.additionalResourceActivities = { [weak self] in
            guard let self else { return [:] }
            return self.nativeDrives.reduce(into: [:]) { result, drive in result.merge(drive.resourceActivities, uniquingKeysWith: { _, new in new }) }
        }
        pikpak.additionalResourceDescriptions = { [weak self] in
            guard let self else { return [] }
            return self.nativeDrives.flatMap { drive in
                drive.activity.active.map { "\(drive.kind.title): \($0.progress.message)" }
                    + (drive.similarity.local.isRunning ? ["\(drive.kind.title): \(drive.similarity.local.message)"] : [])
            }
        }
        local.connect(ICloudDriveProvider(rootURL: localRootURL ?? FileManager.default.homeDirectoryForCurrentUser, kind: .local))
        local.onSendToPikPak = { [weak self] urls in
            guard let self else { return }
            if self.pikpak.uploadDroppedLocalItems(urls, to: self.pikpak.effectiveUploadDestination) {
                self.open(.pikpak)
                self.pikpakNavigation.showImmediately(FinderWorkspaceSection.transfers.rawValue)
                WorkspaceSessionManager.current?.activateBrowser(in: self)
            }
        }
        configureSimilarityDrives()
        if restoreConnections {
            if localRootURL == nil, let data = defaults.data(forKey: "myCloudDriver.localBookmark") {
                restoreLocalFolder(data)
            }
            if let data = defaults.data(forKey: "myCloudDriver.iCloudBookmark") {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                    if url.startAccessingSecurityScopedResource() { scopedICloudURL = url }
                    icloud.connect(ICloudDriveProvider(rootURL: url))
                    if stale { defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "myCloudDriver.iCloudBookmark") }
                } catch { connectionError = "Reconnect iCloud Drive to restore access to its folder." }
            }
            if hasPhotosPermission && !defaults.bool(forKey: Self.photosDisconnectedKey) {
                photos.connect(photosAccess.provider())
            }
        }
    }
    func nativeDrive(for kind: CloudDriveKind) -> NativeDriveModel? {
        switch kind { case .icloud: return icloud; case .photos: return photos; case .local: return local; case .pikpak: return nil }
    }
    var similarityEntryDrive: CloudDriveKind {
        if let selected { return selected }
        let host = pikpak.fileSimilarity, scan = host.activeModel
        if scan.isRunning || scan.isPaused || scan.report != nil || scan.savedSession != nil {
            return CloudDriveKind(rawValue: host.selectedDriveID) ?? .local
        }
        // Local Disk is available without a cloud login or a Photos prompt.
        return .local
    }
    func presentSimilarity() {
        pikpak.fileSimilarity.presentDrive(similarityEntryDrive.rawValue)
    }
    func open(_ kind: CloudDriveKind) {
        if selected != kind {
            pikpak.fileSimilarity.browserRevealTask?.cancel()
            pikpak.previewPlayer?.pause(); nativeDrives.forEach { $0.mediaPreview.clear() }
        }
        // Every drive entry starts in Browser, including a drive that was
        // previously showing Links or Transfers.
        pikpakNavigation.showImmediately(0)
        nativeDrive(for: kind)?.section = 0
        selected = kind
    }
    private func configureSimilarityDrives() {
        let options = CloudDriveKind.allCases.map { kind in
            SimilarityDriveOption(id: kind.rawValue, title: kind.title, symbol: kind.symbol, source: kind == .pikpak ? .cloud : .local)
        }
        let host = pikpak.fileSimilarity
        for coordinator in [host] + nativeDrives.map(\.similarity) {
            coordinator.driveOptions = options
            coordinator.resolveDrive = { [weak self] id in
                guard let self, let kind = CloudDriveKind(rawValue: id) else { return nil }
                return kind == .pikpak ? self.pikpak.fileSimilarity : self.nativeDrive(for: kind)?.similarity
            }
        }
        host.revealInBrowser = { [weak self] source, file in
            guard let self else { return }
            self.open(source == .cloud ? .pikpak : .local)
            if source == .cloud { self.pikpak.revealSimilarityInBrowser(file) }
            else { self.local.revealSimilarityFile(file) }
            WorkspaceSessionManager.current?.activateBrowser(in: self)
        }
        for drive in nativeDrives {
            drive.similarity.preferredDriveID = drive.kind.rawValue
            drive.similarity.presentationHost = host
            drive.similarity.chooseDriveScope = { [weak drive] _, selected in
                guard let drive else { return }
                guard drive.isConnected else {
                    drive.similarity.local.error = "Connect \(drive.kind.title) in Settings → Drives, then choose a scan folder."
                    return
                }
                if selected && drive.selectedItems.isEmpty {
                    drive.similarity.local.error = "Select files or folders in the \(drive.kind.title) Browser first, then use that selection here."
                    return
                }
                drive.similarity.local.error = nil
                drive.findSimilar(selected ? drive.selectedItems : [], exactOnly: drive.similarity.duplicatesOnly, presentWindow: false)
            }
            drive.similarity.revealInBrowser = { [weak self, weak drive] _, file in
                guard let self, let drive else { return }
                self.open(drive.kind); drive.revealSimilarityFile(file)
                WorkspaceSessionManager.current?.activateBrowser(in: self)
            }
        }
    }
    func connectLocal() {
        guard !local.isBusy else { connectionError = "Finish or cancel local work before changing its connected folder."; return }
        let panel = NSOpenPanel(); panel.title = "Choose a Local Folder or Disk"; panel.prompt = "Open Folder"
        panel.message = "Choose a folder on this Mac or an external disk. This becomes the Local Disk browser’s starting location."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = local.provider?.root.url
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.connectLocalFolder(url) }
        }
    }
    func connectLocalFolder(_ url: URL, remember: Bool = true) {
        guard !local.isBusy else { connectionError = "Finish or cancel local work before changing its connected folder."; return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            try LocalFileAccess.validate(url, directory: true)
            if remember {
                let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.pathKey, .volumeUUIDStringKey], relativeTo: nil)
                defaults.set(data, forKey: "myCloudDriver.localBookmark")
                defaults.set(url.path, forKey: "myCloudDriver.localFolderPath")
                defaults.set(LocalFileAccess.volumeID(url), forKey: "myCloudDriver.localVolumeID")
            }
            scopedLocalURL?.stopAccessingSecurityScopedResource()
            scopedLocalURL = scoped ? url : nil
            local.connect(ICloudDriveProvider(rootURL: url, kind: .local)); local.section = 0
            connectionError = nil
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            connectionError = error.localizedDescription
        }
    }
    private func restoreLocalFolder(_ data: Data) {
        let values = URL.resourceValues(forKeys: [.pathKey, .volumeUUIDStringKey], fromBookmarkData: data)
        let path = defaults.string(forKey: "myCloudDriver.localFolderPath") ?? values?.path
        let volumeID = defaults.string(forKey: "myCloudDriver.localVolumeID") ?? values?.volumeUUIDString
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { scopedLocalURL = url }
            local.connect(ICloudDriveProvider(rootURL: url, kind: .local, volumeID: volumeID))
            // Never replace the saved identity while its disk is unavailable.
            if local.isConnected {
                defaults.set(url.path, forKey: "myCloudDriver.localFolderPath")
                defaults.set(LocalFileAccess.volumeID(url), forKey: "myCloudDriver.localVolumeID")
                if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: [.pathKey, .volumeUUIDStringKey], relativeTo: nil) {
                    defaults.set(refreshed, forKey: "myCloudDriver.localBookmark")
                }
            }
        } catch {
            if let path {
                local.connect(ICloudDriveProvider(rootURL: URL(fileURLWithPath: path), kind: .local, volumeID: volumeID))
            } else {
                local.disconnect()
                connectionError = "Reconnect the saved local folder or disk to restore access."
            }
        }
    }
    func connectICloud() {
        guard !icloud.isBusy else { connectionError = "Finish or cancel iCloud Drive work before reconnecting."; return }
        let panel = NSOpenPanel(); panel.title = "Connect iCloud Drive"; panel.prompt = "Connect Folder"
        panel.message = "Choose iCloud Drive in the sidebar, or select a folder within it. MyCloudDriver will remember this location."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    self.scopedICloudURL?.stopAccessingSecurityScopedResource()
                    self.scopedICloudURL = url.startAccessingSecurityScopedResource() ? url : nil
                    self.defaults.set(data, forKey: "myCloudDriver.iCloudBookmark")
                    self.icloud.connect(ICloudDriveProvider(rootURL: url)); self.connectionError = nil
                    self.icloudStorage.clear(); self.icloudStorage.refresh(force: true)
                } catch { self.connectionError = error.localizedDescription }
            }
        }
    }
    var hasPhotosPermission: Bool { photosAuthorization == .authorized || photosAuthorization == .limited }
    var photosPermissionTitle: String {
        switch photosAuthorization {
        case .authorized: return "Full library access allowed"
        case .limited: return "Limited library access allowed"
        case .denied: return "Access denied in macOS"
        case .restricted: return "Access restricted by macOS"
        case .notDetermined: return "Permission not requested"
        @unknown default: return "Access unavailable"
        }
    }
    var photosConnectionTitle: String {
        if connectingPhotos { return "Checking access…" }
        if photos.isConnected { return hasPhotosPermission ? "Connected" : "Access unavailable" }
        return "Disconnected"
    }
    func refreshPhotosAuthorization() {
        photosAuthorization = photosAccess.status()
        if !hasPhotosPermission && photos.isConnected {
            if !photos.isBusy { photos.disconnect() }
            photosFeedback = .init(message: "Photos access is unavailable. Review Photos Privacy Settings, then connect again.", isError: true)
        }
    }
    @discardableResult func connectPhotos() -> Task<Void, Never>? {
        guard !connectingPhotos else { return photosConnectionTask }
        guard photos.isConnected || !photos.isBusy else {
            photosFeedback = .init(message: "Finish or cancel Apple Photos work before connecting.", isError: true)
            return nil
        }
        connectingPhotos = true; photosFeedback = nil
        let requestID = UUID(); photosConnectionID = requestID
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if photosConnectionID == requestID { connectingPhotos = false; photosConnectionTask = nil }
            }
            await Task.yield()
            var authorization = photosAccess.status()
            if authorization == .notDetermined { authorization = await photosAccess.request() }
            guard !Task.isCancelled, photosConnectionID == requestID else { return }
            photosAuthorization = authorization; photosLastChecked = Date()
            guard hasPhotosPermission else {
                if photos.isConnected && !photos.isBusy { photos.disconnect() }
                photosFeedback = .init(message: "\(photosPermissionTitle). Allow MyCloudDriver in System Settings → Privacy & Security → Photos, then connect again.", isError: true)
                return
            }
            if photos.isConnected {
                // Checking permission must preserve the current album, selection,
                // Undo history, scan results and any running transfer.
                photosFeedback = .init(message: "Access confirmed. Apple Photos is connected to MyCloudDriver.")
            } else {
                photos.connect(photosAccess.provider())
                guard photos.isConnected else {
                    photosFeedback = .init(message: photos.error ?? "Apple Photos could not connect.", isError: true)
                    return
                }
                defaults.set(false, forKey: Self.photosDisconnectedKey)
                photosFeedback = .init(message: "Apple Photos connected. Open the drive to browse your library.")
            }
        }
        photosConnectionTask = task
        return task
    }
    func disconnectPhotos() {
        guard !connectingPhotos, !photos.isBusy else {
            photosFeedback = .init(message: "Finish or cancel Apple Photos work before disconnecting.", isError: true)
            return
        }
        photos.disconnect()
        defaults.set(true, forKey: Self.photosDisconnectedKey)
        photosFeedback = .init(message: "Apple Photos disconnected from MyCloudDriver. Your library and macOS permission are unchanged.")
    }
    func disconnectICloud() {
        guard !icloud.isBusy else { return }
        icloud.disconnect(); defaults.removeObject(forKey: "myCloudDriver.iCloudBookmark")
        icloudStorage.clear()
        scopedICloudURL?.stopAccessingSecurityScopedResource(); scopedICloudURL = nil
    }
    func close() {
        photosConnectionID = UUID(); photosConnectionTask?.cancel(); photosConnectionTask = nil; connectingPhotos = false
        icloudStorage.clear()
        nativeDrives.forEach { $0.close() }; scopedICloudURL?.stopAccessingSecurityScopedResource(); scopedLocalURL?.stopAccessingSecurityScopedResource()
    }
}

struct MyCloudDriverRootView: View {
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject var settings: FinderSettings
    var body: some View {
        VStack(spacing: 0) {
            if let selected = hub.selected {
                HStack(spacing: 12) {
                    Button { hub.selected = nil } label: { Label("All Drives", systemImage: "square.grid.2x2") }
                        .buttonStyle(.borderless).help("Choose a different drive")
                    Divider().frame(height: 18)
                    Menu {
                        ForEach(CloudDriveKind.allCases) { kind in Button { hub.open(kind) } label: { Label(kind.title, systemImage: kind.symbol) } }
                    } label: { Label(selected.title, systemImage: selected.symbol).font(.headline) }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Text("MyCloudDriver").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).padding(.vertical, 10)
                    .background(FinderAppearance.sidebarBackground.opacity(0.55))
                Divider()
                switch selected {
                case .pikpak: ContentView(navigation: hub.pikpakNavigation).environmentObject(hub.pikpak).environmentObject(settings)
                case .icloud: NativeDriveWorkspace(model: hub.icloud, hub: hub, settings: settings).id(CloudDriveKind.icloud)
                case .photos: NativeDriveWorkspace(model: hub.photos, hub: hub, settings: settings).id(CloudDriveKind.photos)
                case .local: NativeDriveWorkspace(model: hub.local, hub: hub, settings: settings).id(CloudDriveKind.local)
                }
            } else { CloudDriveHome(hub: hub) }
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(FinderAppearance.accent).accentColor(FinderAppearance.accent).buttonStyle(FinderButtonStyle())
        .onReceive(NotificationCenter.default.publisher(for: .init("MyCloudDriverAllDrives"))) { note in
            guard let target = note.object as? CloudDriveHub, target === hub else { return }
            hub.selected = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hub.refreshPhotosAuthorization()
            if hub.icloud.isConnected { hub.icloudStorage.refresh(force: true) }
        }
        .alert("Drive connection", isPresented: Binding(get: { hub.connectionError != nil }, set: { if !$0 { hub.connectionError = nil } })) {
            Button("OK") { hub.connectionError = nil }
        } message: { Text(hub.connectionError ?? "") }
    }
}

struct CloudDriveHome: View {
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject private var pikpak: DownloaderModel
    @ObservedObject private var icloud: NativeDriveModel
    @ObservedObject private var photos: NativeDriveModel
    @ObservedObject private var local: NativeDriveModel
    init(hub: CloudDriveHub) { self.hub = hub; pikpak = hub.pikpak; icloud = hub.icloud; photos = hub.photos; local = hub.local }
    private var pikpakStatus: (title: String, color: Color) {
        if pikpak.isCheckingAccount || pikpak.isChangingAccount {
            return ("Checking account…", FinderAppearance.accent)
        }
        switch pikpak.accountLoginStatus {
        case .signedIn: return ("Signed in", .green)
        case .checking: return (pikpak.accountLoginStatus.title, FinderAppearance.accent)
        case .needsSignIn, .unavailable: return (pikpak.accountLoginStatus.title, .orange)
        case .unverified, .signedOut:
            return pikpak.hasAccountSession ? ("Account saved", .green) : ("Sign in to connect", .orange)
        }
    }
    private var photosStatus: (title: String, color: Color) {
        if hub.connectingPhotos { return ("Checking access…", FinderAppearance.accent) }
        guard hub.hasPhotosPermission else {
            return (hub.photosAuthorization == .notDetermined ? "Allow library access" : hub.photosPermissionTitle, .orange)
        }
        return photos.isConnected ? (hub.photosConnectionTitle, .green) : ("Disconnected · Connect to browse", .secondary)
    }
    var body: some View {
        GeometryReader { viewport in
        let compact = viewport.size.width < 900 || viewport.size.height < 650
        let columnCount = viewport.size.width >= 1120 ? 4 : viewport.size.width >= 620 ? 2 : 1
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 22 : 30) {
                HStack {
                    Label("MyCloudDriver", systemImage: "externaldrive.badge.icloud").font(.title3.weight(.semibold))
                    Spacer(); FinderSettingsButton().frame(width: 144)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your drives, one workspace.").font(.system(size: compact ? 28 : 34, weight: .semibold))
                    Text("Choose a drive to browse, organise and compare your files.")
                        .font(.title3).foregroundStyle(.secondary)
                }.padding(.top, compact ? 12 : 35)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: columnCount), alignment: .leading, spacing: 18) {
                    card(.pikpak, state: pikpakStatus.title, statusColor: pikpakStatus.color, compact: compact)
                    card(.icloud, state: icloud.isConnected ? "Folder connected" : "Connect a folder",
                         statusColor: icloud.isConnected ? .green : .orange, compact: compact)
                    card(.photos, state: photosStatus.title, statusColor: photosStatus.color, compact: compact)
                    card(.local, state: local.isConnected ? "Ready on this Mac" : "Choose a folder", statusColor: local.isConnected ? .green : .orange, compact: compact)
                }
                let featureLayout = viewport.size.width < 700 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                featureLayout {
                    feature("Browse your way", "Lists, thumbnails and Finder-style previews.", "rectangle.split.2x1")
                    feature("Find related files", "Duplicate and similarity scans in each drive.", "doc.text.magnifyingglass")
                    feature("Keep working", "Transfers and scans continue when you switch.", "arrow.triangle.2.circlepath")
                }.padding(.top, 8)
                Text("iCloud Drive and Photos use the account configured on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(compact ? 20 : 32).frame(maxWidth: 1440)
                .frame(maxWidth: .infinity, alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func card(_ kind: CloudDriveKind, state: String, statusColor: Color, compact: Bool) -> some View {
        Button { hub.open(kind) } label: {
            VStack(alignment: .leading, spacing: compact ? 14 : 18) {
                Image(systemName: kind.symbol).font(.system(size: 28)).foregroundStyle(FinderAppearance.accent)
                    .frame(width: compact ? 54 : 62, height: compact ? 54 : 62).background(FinderAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.title).font(.title2.weight(.semibold))
                    Text(kind.subtitle).font(.callout).foregroundStyle(.secondary).frame(height: 54, alignment: .top)
                }
                Label {
                    Text(state).foregroundStyle(.secondary)
                } icon: {
                    Circle().fill(statusColor).frame(width: 9, height: 9).accessibilityHidden(true)
                }.font(.caption)
                HStack { Text("Open \(kind.title)").fontWeight(.medium); Spacer(); Image(systemName: "arrow.right") }
                    .foregroundStyle(FinderAppearance.accent)
            }.padding(compact ? 18 : 24).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.09)))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).pointingHandCursor().help("Open \(kind.title)")
    }
    private func feature(_ title: String, _ description: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            Text(description).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CloudDriveConnectionsView: View {
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject var icloud: NativeDriveModel
    @ObservedObject var photos: NativeDriveModel
    @ObservedObject var local: NativeDriveModel
    init(hub: CloudDriveHub) { self.hub = hub; icloud = hub.icloud; photos = hub.photos; local = hub.local }
    var body: some View {
        Form {
            Section("Local Disk") {
                CloudDriveIdentityRow(kind: .local, detail: "Folders and external disks on this Mac", status: local.isConnected ? "Available" : "Choose a folder", connected: local.isConnected)
                if let root = local.provider?.root.url { Text(root.path).font(.caption).textSelection(.enabled) }
                Button("Choose Folder or Disk…") { hub.connectLocal() }.disabled(local.isBusy)
                Text("Local files stay on this Mac unless you explicitly copy or upload them. macOS controls access to protected folders.").font(.caption).foregroundStyle(.secondary)
            }
            Section("iCloud Drive") {
                CloudDriveIdentityRow(kind: .icloud, detail: "Folder access on this Mac",
                    status: icloud.isConnected ? "Connected" : "Disconnected", connected: icloud.isConnected)
                if let root = icloud.provider?.root.url { Text(root.path).font(.caption).textSelection(.enabled) }
                HStack {
                    Button(icloud.isConnected ? "Change Folder…" : "Connect Folder…") { hub.connectICloud() }.disabled(icloud.isBusy)
                    if icloud.isConnected { Button("Disconnect") { hub.disconnectICloud() }.disabled(icloud.isBusy) }
                }
                Text("Choose iCloud Drive or one of its folders in the system file picker.").font(.caption).foregroundStyle(.secondary)
                FinderICloudStorageSettings(storage: hub.icloudStorage, connected: icloud.isConnected)
            }
            Section("Apple Photos") {
                CloudDriveIdentityRow(kind: .photos, detail: "Photos library on this Mac",
                    status: hub.photosConnectionTitle, connected: photos.isConnected && hub.hasPhotosPermission)
                LabeledContent("macOS permission", value: hub.photosPermissionTitle)
                    .font(.callout)
                HStack {
                    Button { hub.connectPhotos() } label: {
                        HStack(spacing: 6) {
                            if hub.connectingPhotos { ProgressView().controlSize(.small) }
                            Text(hub.connectingPhotos ? "Checking Access…" : photos.isConnected ? "Check Access" : "Connect Photos")
                        }
                    }
                    .disabled(hub.connectingPhotos)
                    .help("Check macOS permission and connect Apple Photos without resetting your current album")
                    Spacer()
                    Button("Disconnect") { hub.disconnectPhotos() }
                        .disabled(!photos.isConnected || hub.connectingPhotos || photos.isBusy)
                        .help("Disconnect Apple Photos from MyCloudDriver; keep the library and macOS permission")
                }
                PhotosConnectionFeedbackView(hub: hub)
                if let checked = hub.photosLastChecked {
                    Text("Last checked \(checked.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if photos.isBusy {
                    Text("Disconnect is available after Apple Photos transfers and scans finish or are cancelled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Photos Privacy Settings…", action: openPhotosPrivacySettings)
                Text("Disconnect keeps this app disconnected after relaunch. To revoke macOS permission, use Photos Privacy Settings. Your photos, videos and albums stay in Photos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("PikPak") {
                Text("Manage PikPak sign-in and saved accounts in the Accounts tab.").font(.callout)
                Button("Manage PikPak Accounts") { hub.pikpak.finderSettings.selectedPane = 2 }
            }
        }.formStyle(.grouped)
            .onAppear { hub.refreshPhotosAuthorization() }
    }
}

private struct CloudDriveIdentityRow: View {
    let kind: CloudDriveKind
    let detail: String
    let status: String
    let connected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.title2).foregroundStyle(FinderAppearance.accent)
                .frame(width: 36, height: 36)
                .background(FinderAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(status, systemImage: connected ? "checkmark.circle.fill" : "circle")
                .font(.caption).foregroundStyle(connected ? Color.green : .secondary)
        }.padding(.vertical, 4)
    }
}

struct CloudDriveAccountsSummary: View {
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject private var icloud: NativeDriveModel
    @ObservedObject private var photos: NativeDriveModel
    init(hub: CloudDriveHub) { self.hub = hub; icloud = hub.icloud; photos = hub.photos }
    var body: some View {
        CloudDriveIdentityRow(kind: .icloud, detail: "Apple Account managed in macOS",
            status: icloud.isConnected ? "Connected" : "Disconnected", connected: icloud.isConnected)
        CloudDriveIdentityRow(kind: .photos, detail: "Photos library on this Mac",
            status: hub.photosConnectionTitle, connected: photos.isConnected && hub.hasPhotosPermission)
        Text("These services use your Mac’s Apple Account and Photos library. This app does not receive your Apple Account name or email. Check the account in System Settings; manage app access in Drives.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Manage Apple Drive Connections…") { hub.pikpak.finderSettings.selectedPane = 3 }
    }
}

struct PhotosConnectionFeedbackView: View {
    @ObservedObject var hub: CloudDriveHub
    var body: some View {
        if let feedback = hub.photosFeedback {
            Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.callout).foregroundStyle(feedback.isError ? Color.orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }
}

func openPhotosPrivacySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
}
