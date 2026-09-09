import AppKit
import SwiftUI
@preconcurrency import Photos

@MainActor final class CloudDriveHub: ObservableObject {
    @Published var selected: CloudDriveKind?
    @Published var connectionError: String?
    @Published var connectingPhotos = false
    let pikpak: DownloaderModel
    let pikpakNavigation = FinderWorkspaceNavigation()
    let icloud = NativeDriveModel(kind: .icloud)
    let photos = NativeDriveModel(kind: .photos)
    private let defaults: UserDefaults
    private var scopedICloudURL: URL?
    init(pikpak: DownloaderModel, defaults: UserDefaults = .standard, restoreConnections: Bool = true) {
        self.pikpak = pikpak; self.defaults = defaults
        for drive in [icloud, photos] {
            let name = drive.kind.rawValue
            drive.scanConfiguration = { [weak pikpak] in
                guard let pikpak else { throw CocoaError(.userCancelled) }
                return try pikpak.nativeSimilarityConfiguration(drive: name)
            }
        }
        pikpak.additionalResourceActivities = { [weak self] in
            guard let self else { return [:] }
            return self.icloud.resourceActivities.merging(self.photos.resourceActivities, uniquingKeysWith: { _, new in new })
        }
        pikpak.additionalResourceDescriptions = { [weak self] in
            guard let self else { return [] }
            return [self.icloud, self.photos].flatMap { drive in
                drive.activity.active.map { "\(drive.kind.title): \($0.progress.message)" }
                    + (drive.similarity.local.isRunning ? ["\(drive.kind.title): \(drive.similarity.local.message)"] : [])
            }
        }
        if restoreConnections {
            if let data = defaults.data(forKey: "myCloudDriver.iCloudBookmark") {
                do {
                    var stale = false
                    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                    if url.startAccessingSecurityScopedResource() { scopedICloudURL = url }
                    icloud.connect(ICloudDriveProvider(rootURL: url))
                    if stale { defaults.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "myCloudDriver.iCloudBookmark") }
                } catch { connectionError = "Reconnect iCloud Drive to restore access to its folder." }
            }
            if PhotosDriveProvider.authorized { photos.connect(PhotosDriveProvider()) }
        }
    }
    func open(_ kind: CloudDriveKind) { selected = kind }
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
                } catch { self.connectionError = error.localizedDescription }
            }
        }
    }
    func connectPhotos() {
        guard !connectingPhotos else { return }; connectingPhotos = true
        Task {
            defer { connectingPhotos = false }
            do { try await PhotosDriveProvider.connect(); photos.connect(PhotosDriveProvider()); connectionError = nil }
            catch { connectionError = error.localizedDescription }
        }
    }
    func disconnectICloud() {
        guard !icloud.isBusy else { return }
        icloud.disconnect(); defaults.removeObject(forKey: "myCloudDriver.iCloudBookmark")
        scopedICloudURL?.stopAccessingSecurityScopedResource(); scopedICloudURL = nil
    }
    func close() { icloud.close(); photos.close(); scopedICloudURL?.stopAccessingSecurityScopedResource() }
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
                case .icloud: NativeDriveWorkspace(model: hub.icloud, hub: hub, settings: settings)
                case .photos: NativeDriveWorkspace(model: hub.photos, hub: hub, settings: settings)
                }
            } else { CloudDriveHome(hub: hub) }
        }
        .frame(minWidth: 1000, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(FinderAppearance.accent).accentColor(FinderAppearance.accent).buttonStyle(FinderButtonStyle())
        .navigationTitle("MyCloudDriver")
        .onReceive(NotificationCenter.default.publisher(for: .init("MyCloudDriverAllDrives"))) { _ in hub.selected = nil }
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
    init(hub: CloudDriveHub) { self.hub = hub; pikpak = hub.pikpak; icloud = hub.icloud; photos = hub.photos }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Label("MyCloudDriver", systemImage: "externaldrive.badge.icloud").font(.title3.weight(.semibold))
                    Spacer(); FinderSettingsButton().frame(width: 144)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your drives, one workspace.").font(.system(size: 34, weight: .semibold))
                    Text("Choose a drive to browse, organise and compare your files.")
                        .font(.title3).foregroundStyle(.secondary)
                }.padding(.top, 35)
                HStack(alignment: .top, spacing: 18) {
                    card(.pikpak, state: pikpak.hasAccountSession ? "Account saved" : "Sign in to connect")
                    card(.icloud, state: icloud.isConnected ? "Folder connected" : "Connect a folder")
                    card(.photos, state: photos.isConnected ? "Library access enabled" : "Allow library access")
                }
                HStack(alignment: .top, spacing: 32) {
                    feature("Browse your way", "Lists, thumbnails and Finder-style previews.", "rectangle.split.2x1")
                    feature("Find related files", "Duplicate and similarity scans in each drive.", "doc.text.magnifyingglass")
                    feature("Keep working", "Transfers and scans continue when you switch.", "arrow.triangle.2.circlepath")
                }.padding(.top, 8)
                Text("iCloud Drive and Photos use the account configured on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(42).frame(maxWidth: 1240)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func card(_ kind: CloudDriveKind, state: String) -> some View {
        Button { hub.open(kind) } label: {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: kind.symbol).font(.system(size: 28)).foregroundStyle(FinderAppearance.accent)
                    .frame(width: 62, height: 62).background(FinderAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.title).font(.title2.weight(.semibold))
                    Text(kind.subtitle).font(.callout).foregroundStyle(.secondary).frame(height: 40, alignment: .top)
                }
                Label(state, systemImage: "circle.fill").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Open \(kind.title)").fontWeight(.medium); Spacer(); Image(systemName: "arrow.right") }
                    .foregroundStyle(FinderAppearance.accent)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
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
    init(hub: CloudDriveHub) { self.hub = hub; icloud = hub.icloud; photos = hub.photos }
    var body: some View {
        Form {
            Section("iCloud Drive") {
                Label(icloud.isConnected ? "Connected" : "Not connected", systemImage: "icloud")
                if let root = icloud.provider?.root.url { Text(root.path).font(.caption).textSelection(.enabled) }
                HStack {
                    Button(icloud.isConnected ? "Change Folder…" : "Connect Folder…") { hub.connectICloud() }.disabled(icloud.isBusy)
                    if icloud.isConnected { Button("Disconnect") { hub.disconnectICloud() }.disabled(icloud.isBusy) }
                }
                Text("Choose iCloud Drive or one of its folders in the system file picker.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Photos") {
                Label(PhotosDriveProvider.authorized ? "Library access enabled" : "Library access required", systemImage: "photo.on.rectangle")
                Button("Connect / Check Access") { hub.connectPhotos() }.disabled(hub.connectingPhotos || photos.isBusy)
                Button("Photos Privacy Settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!) }
                Text("Library access is controlled by macOS. Photos uses albums, and deleted media can be recovered in Photos → Recently Deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("PikPak") {
                Text("Manage PikPak sign-in and saved accounts in the Accounts tab.").font(.callout)
                Button("Manage PikPak Accounts") { hub.pikpak.finderSettings.selectedPane = 2 }
            }
        }.formStyle(.grouped)
    }
}
