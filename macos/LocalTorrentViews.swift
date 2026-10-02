import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalTorrentDraft: Identifiable {
    let id = UUID()
    var magnet = ""
    var jobID: UUID?
}

/// Observe login readiness independently of the large workspace view. A
/// restored queue can start even when the user has not opened Transfers.
struct LocalTorrentLaunchRestoration: View {
    @ObservedObject var account: DownloaderModel
    private var session: String {
        let identity = account.activeAccountID?.uuidString ?? ""
        let owner = account.activeSavedAccount?.profile?.sub ?? account.accountProfile?.sub ?? ""
        let ready = account.hasAccountSession && !account.isChangingAccount
        return "\(identity):\(owner):\(ready)"
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).task(id: session) {
            let torrents = LocalTorrentModel.shared
            torrents.configureRelayAccount(account)
            await torrents.resumeRestoredTransfers()
        }
    }
}

enum LocalTorrentFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    static func speed(_ value: UInt64) -> String { value == 0 ? "0 B/s" : bytes(value) + "/s" }
    static func percentage(_ fraction: Double) -> String {
        min(1, max(0, fraction)).formatted(.percent.precision(.fractionLength(1)))
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 120 { return "\(total) seconds" }
        let minutes = total / 60
        if minutes < 120 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
    static func peerConnections(_ job: LocalTorrentJob) -> String {
        let connected = "\(job.peers) connected \(job.peers == 1 ? "peer" : "peers")"
        guard let attempted = job.attempted, attempted > job.peers else { return connected }
        return connected + " · \(attempted - job.peers) trying"
    }
}

private struct LocalTorrentPeerStats: View {
    let job: LocalTorrentJob

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { peers; speeds }
            VStack(alignment: .leading, spacing: 6) { peers; speeds }
        }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
    }

    private var peers: some View {
        Text("\(LocalTorrentFormat.peerConnections(job)) · \(seedSummary)")
            .help(job.files.isEmpty
                ? "The seed count is unknown until the file list is loaded. Connected peers may still supply the file list."
                : "Peers that completed the BitTorrent handshake, including seeds. Seeds have the complete torrent. Attempts are connections still being opened, most of which never answer. This is not the total swarm size.")
    }

    private var seedSummary: String {
        // aria2 ignores peers' piece bitfields while fetching magnet metadata,
        // so numSeeders cannot classify seeds during this stage.
        job.files.isEmpty ? "Seeds: unknown" : "\(job.seeders) connected \(job.seeders == 1 ? "seed" : "seeds")"
    }

    private var speeds: some View {
        HStack(spacing: 20) {
            Label(LocalTorrentFormat.speed(job.downloadSpeed), systemImage: "arrow.down")
                .help("Current download speed from peers")
                .accessibilityLabel("Download speed: \(LocalTorrentFormat.speed(job.downloadSpeed))")
            Label(LocalTorrentFormat.speed(job.uploadSpeed), systemImage: "arrow.up")
                .help("Current upload speed to peers")
                .accessibilityLabel("Upload speed: \(LocalTorrentFormat.speed(job.uploadSpeed))")
        }
    }
}

/// Connected peers and this Mac's download and upload rates with each one.
///
/// Collapsed by default. The swarm is detail rather than headline, and a card
/// that opened with fifty rows would bury the transfer it belongs to.
struct LocalTorrentPeerList: View {
    let peers: [LocalTorrentPeer]
    /// Peers aria2 counts, which can exceed the busiest few listed here.
    let connected: Int
    @State private var expanded = false

    private var downloading: Int { peers.filter { $0.downloadSpeed > 0 }.count }
    private var uploading: Int { peers.filter { $0.uploadSpeed > 0 }.count }

    var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    if peers.isEmpty {
                        Text("No connected peers right now.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ScrollView { VStack(spacing: 4) { ForEach(peers, id: \.address, content: row) } }
                        .frame(maxHeight: peers.count > 6 ? 150 : nil)
                    if peers.count < connected {
                        Text("Busiest \(peers.count) of \(connected) shown.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.top, 5)
            } label: {
                HStack(spacing: 14) {
                    Text("Peers")
                    Label("\(downloading) downloading", systemImage: "arrow.down")
                        .accessibilityLabel("Downloading from \(downloading) peers")
                    Label("\(uploading) uploading", systemImage: "arrow.up")
                        .accessibilityLabel("Uploading to \(uploading) peers")
                }.help("Connected peers and their current rates, refreshed every few seconds. Downloading transfers data from peers to this Mac; uploading transfers data from this Mac to peers.")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func row(_ peer: LocalTorrentPeer) -> some View {
        HStack(spacing: 8) {
            Circle().fill(peer.active ? Color.green.opacity(0.75) : Color.secondary.opacity(0.3))
                .frame(width: 5, height: 5)
            Text(peer.address).lineLimit(1).truncationMode(.middle)
            if let transport = peer.transport {
                Text(transport == "utp" ? "µTP" : "TCP").font(.caption2).foregroundStyle(.secondary)
            }
            if peer.seeder {
                Text("seed").font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 8)
            Label(LocalTorrentFormat.speed(peer.downloadSpeed), systemImage: "arrow.down")
                .frame(width: 86, alignment: .trailing)
            Label(LocalTorrentFormat.speed(peer.uploadSpeed), systemImage: "arrow.up")
                .frame(width: 86, alignment: .trailing)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("Peer \(peer.address), downloading \(LocalTorrentFormat.speed(peer.downloadSpeed)), uploading \(LocalTorrentFormat.speed(peer.uploadSpeed))")
    }
}

private struct LocalTorrentConnectionDetails: View {
    let diagnostics: LocalTorrentNetworkDiagnostics
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Connection details", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(diagnostics.knownPeers) peer addresses discovered. An address is counted as connected only after its BitTorrent handshake finishes.")
                Text("Trackers: \(diagnostics.trackersResponding) responding · \(diagnostics.trackersFailed) failing · \(diagnostics.trackerCount) configured")
                if !diagnostics.dhtEnabled { Text("DHT: disabled") }
                else if let nodes = diagnostics.dhtNodes { Text("DHT: \(nodes) routing nodes") }
                else { Text("DHT: collecting connection status…") }
                if !diagnostics.lastPeerError.isEmpty {
                    Text("Last peer connection failure: \(diagnostics.lastPeerError)")
                }
            }.fixedSize(horizontal: false, vertical: true).padding(.top, 5)
        }.font(.caption).foregroundStyle(.secondary)
            .help("Network counters only. This does not inspect downloaded files. Discovery does not guarantee that a peer is online or will complete a connection.")
    }
}

struct LocalTorrentWorkspace: View {
    @ObservedObject var model: LocalTorrentModel = .shared
    var pikpak: DownloaderModel? = nil
    @State private var restarting: LocalTorrentJob?
    @State private var draft: LocalTorrentDraft?
    @State private var removing: LocalTorrentJob?
    @State private var configuringStorage: LocalTorrentJob?

    var body: some View {
        FinderTransferWorkspace(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heading; Spacer(minLength: 12); newTorrentButton }
                VStack(alignment: .leading, spacing: 10) { heading; newTorrentButton }
            }
            Text("Uses BitTorrent peers and this Mac’s internet connection. Peer uploads share 4 MB/s across torrents, and a PikPak transfer seeds at 256 KB/s so its uplink goes to the upload. Seeding stops when each download finishes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").lineLimit(3).help(error)
                    Spacer(minLength: 8)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss torrent error")
                }.font(.callout).foregroundStyle(.orange).padding(12)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(spacing: 12) {
            if model.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(nsImage: FinderSymbolImage.template(named: "arrow.down.circle", style: .menu))
                        .foregroundStyle(.secondary)
                    Text("Choose where your torrent goes").font(.headline)
                    Text("Choose files from a magnet link or .torrent file, then save to this Mac or upload to PikPak using a RAM buffer.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 410)
                    Button("Add Magnet or Torrent…") { draft = .init() }.disabled(!model.storageAvailable)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).finderCard(padding: 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.jobs.reversed()) { job in
                            LocalTorrentRow(job: job, busy: model.busy.contains(job.id),
                                peers: model.connectedPeers(job.id), torrentRunning: model.torrentIsLive(job.id),
                                diagnostics: model.networkDetails[job.id],
                                account: pikpak,
                                choose: { draft = .init(jobID: job.id) },
                                pause: { Task { await model.pause(job.id) } },
                                resume: { Task { await model.resume(job.id) } },
                                stop: { Task { await model.stop(job.id) } },
                                restart: { restarting = job }, switchToStorage: { chooseStorage(for: job) },
                                keepUploadedFiles: { model.setKeepUploadedFiles(job.id, enabled: $0) },
                                configureStorage: { configuringStorage = job },
                                reveal: { model.reveal(job.id) }, remove: { removing = job })
                        }
                    }.padding(1)
                }
            }
            FinderTransferActionLayout {
                Text("\(model.jobs.filter { $0.phase.active }.count) active · \(model.jobs.count) torrents")
                Text("Saved progress is available after reopening the app.")
            }.font(.caption).foregroundStyle(.secondary)
            }.frame(minHeight: 260)
        }
        .sheet(item: $draft) { value in LocalTorrentAddSheet(model: model, draft: value, pikpak: pikpak) }
        .sheet(item: $configuringStorage) { job in TorrentStorageLimitSheet(model: model, job: job) }
        .onAppear { if let pikpak { model.configureRelayAccount(pikpak) } }
        .alert(item: $removing) { job in
            Alert(title: Text("Remove “\(job.name)” from Transfers?"),
                  message: Text(job.relay == nil ? "The torrent will stop. Downloaded and partial files stay in their folder." : job.relay?.storage != nil ? "The torrent will stop. Files already saved to PikPak are kept, and remaining local files stay in the storage folder. Removing this record also removes its resume history." : "The torrent will stop and release its RAM buffer. Completed PikPak files are kept. Removing this record also removes its resume history."),
                  primaryButton: .destructive(Text("Remove Torrent")) { Task { await model.remove(job.id) } },
                  secondaryButton: .cancel())
        }
        .confirmationDialog("Restart unfinished downloads?", isPresented: Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } }), titleVisibility: .visible) {
            if let job = restarting {
                Button("Restart Download") { Task { await model.restartRelay(job.id) }; restarting = nil }
                Button("Cancel", role: .cancel) { restarting = nil }
            }
        } message: { Text("Unfinished RAM data will be downloaded again. Files already saved to PikPak will be kept and skipped.") }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Image(nsImage: FinderSymbolImage.template(named: "arrow.down.doc", style: .menu))
                .foregroundStyle(FinderAppearance.accent).padding(12)
                .background(FinderAppearance.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("Torrent Transfers").font(.title2.weight(.semibold))
                Text("Download to this Mac or send files to PikPak through RAM or storage.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var newTorrentButton: some View {
        Button { draft = .init() } label: { Label("New Torrent…", systemImage: "plus") }
            .buttonStyle(.borderedProminent).disabled(!model.storageAvailable)
    }

    private func chooseStorage(for job: LocalTorrentJob) {
        let panel = NSOpenPanel()
        panel.title = "Switch Torrent to Storage"
        panel.message = "Choose a folder for torrent data. Existing RAM data will move here and continue uploading to PikPak. Uploaded copies stay available for sharing within the storage limit. By default, 100 GB of drive space is left free."
        panel.prompt = "Switch to Storage"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let parent = panel.url else { return }
            Task { await model.switchRelayToStorage(job.id, parent: parent) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

private struct LocalTorrentRow: View {
    let job: LocalTorrentJob
    let busy: Bool
    let peers: [LocalTorrentPeer]
    let torrentRunning: Bool
    let diagnostics: LocalTorrentNetworkDiagnostics?
    let account: DownloaderModel?
    let choose: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let stop: () -> Void
    let restart: () -> Void
    let switchToStorage: () -> Void
    let keepUploadedFiles: (Bool) -> Void
    let configureStorage: () -> Void
    let reveal: () -> Void
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    title; Spacer(minLength: 8)
                    HStack(spacing: 8) { actions }.fixedSize(horizontal: true, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    FinderTransferActionLayout { actions }
                }
            }
            if let relay = job.relay { TorrentRelayProgress(job: job, relay: relay, peers: peers, torrentRunning: torrentRunning, account: account) }
            else if job.phase == .metadata { ProgressView().progressViewStyle(.linear) }
            else if job.destination != nil { ProgressView(value: job.progress).progressViewStyle(.linear) }
            if job.relay == nil && (job.files.isEmpty || job.destination != nil) {
                LocalTorrentPeerStats(job: job)
                LocalTorrentPeerList(peers: peers, connected: job.peers)
            }
            if job.phase.active, let diagnostics { LocalTorrentConnectionDetails(diagnostics: diagnostics) }
            if job.destination != nil {
                FinderTransferActionLayout(spacing: 20) {
                    Text("\(LocalTorrentFormat.bytes(job.completed)) of \(LocalTorrentFormat.bytes(job.total))")
                    Text(job.downloadEstimate)
                    Text(LocalTorrentFormat.percentage(job.downloadProgress))
                }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else if !job.files.isEmpty && job.relay == nil {
                Text("\(job.payloadFiles.count.formatted()) files · \(LocalTorrentFormat.bytes(job.total)) available")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(job.message) }
            if let path = job.localFolder {
                Button(action: reveal) { Label(path, systemImage: "folder").lineLimit(1).truncationMode(.middle) }
                    .buttonStyle(.borderless).font(.caption).help(path)
            }
        }.finderCard(padding: 16)
    }
    private var title: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline).lineLimit(2).help(job.name)
                Text(job.status).font(.caption).foregroundStyle(job.phase == .failed ? Color.orange : .secondary)
            }
            if busy { ProgressView().controlSize(.small) }
        }
    }
    @ViewBuilder private var actions: some View {
        Group {
            if job.canChoose { Button("Choose Files…", action: choose).buttonStyle(.borderedProminent) }
            else if job.phase.active || job.retryAt != nil { Button("Pause", action: pause) }
            else if job.phase != .completed { Button(job.files.isEmpty ? "Load File List" : "Resume", action: resume) }
            if job.phase.active || job.phase == .paused || (job.relay?.volume != nil && job.phase == .failed) { Button("Stop", action: stop) }
            Menu {
                if job.canSwitchRelayToStorage { Button("Switch to Storage…", action: switchToStorage) }
                if let relay = job.relay, relay.storage != nil, job.phase != .completed {
                    Button("Storage Limit…", action: configureStorage)
                    Toggle("Keep Uploaded Files for Sharing", isOn: Binding(get: { relay.keepsUploadedFiles }, set: keepUploadedFiles))
                }
                if job.relay != nil && job.relay?.storage == nil && job.phase != .completed { Button("Restart Download…", action: restart) }
                if job.localFolder != nil { Button("Show in Finder", action: reveal) }
                Button("Remove Torrent…", role: .destructive, action: remove)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
                .help("Torrent actions").accessibilityLabel("Torrent actions for \(job.name)")
        }.disabled(busy)
    }
}

struct LocalTorrentAddSheet: View {
    @ObservedObject var model: LocalTorrentModel
    let draft: LocalTorrentDraft
    var onStarted: () -> Void = {}
    let pikpak: DownloaderModel?
    @Environment(\.dismiss) private var dismiss
    @State private var magnet: String
    @State private var jobID: UUID?
    @State private var toPikPak = false
    @State private var memoryBytes = TorrentRelayState.defaultBudget
    @State private var cloudParent = PikPakManagedFile(id: "", name: "My PikPak", isFolder: true, size: 0)
    @State private var cloudContext: PikPakManagementContext?
    @State private var search = ""
    @State private var selected = Set<Int>()
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    @State private var destinationLease: LocalFileAccessLease?
    @State private var localError: String?
    @State private var submitting = false
    @State private var ownsJob = false
    @State private var loadedSelection = false
    private var job: LocalTorrentJob? { jobID.flatMap(model.job) }
    private var busy: Bool { submitting || jobID.map { model.busy.contains($0) } == true }
    private var visibleFiles: [LocalTorrentFile] {
        (job?.payloadFiles ?? []).filter { search.isEmpty || $0.path.localizedStandardContains(search) }
    }
    private var selectedBytes: UInt64 {
        (job?.files ?? []).filter { selected.contains($0.index) }.reduce(0) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.length); return overflow ? UInt64.max : sum
        }
    }

    init(model: LocalTorrentModel? = nil, draft: LocalTorrentDraft, pikpak: DownloaderModel? = nil, onStarted: @escaping () -> Void = {}) {
        self.model = model ?? .shared; self.draft = draft; self.pikpak = pikpak; self.onStarted = onStarted
        _magnet = State(initialValue: draft.magnet); _jobID = State(initialValue: draft.jobID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Download Torrent").font(.title2.weight(.semibold))
                Text(job?.files.isEmpty == false ? "2 · Choose files and where to save them" : "1 · Load the torrent’s file list")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let job {
                HStack {
                    Label(job.name, systemImage: "doc.zipper").font(.callout.weight(.medium)).lineLimit(2)
                    Spacer()
                    if job.destination != nil || job.relay != nil { Text(job.status).foregroundStyle(.secondary) }
                }
                if job.canChoose { fileSelection }
                else {
                    VStack(spacing: 14) {
                        if job.phase == .metadata { ProgressView(); Text("Loading file list from peers…").font(.headline) }
                        else { Text(job.status).font(.headline) }
                        Text(job.message).multilineTextAlignment(.center).foregroundStyle(.secondary).lineLimit(6)
                        if job.phase == .metadata {
                            LocalTorrentPeerStats(job: job)
                            LocalTorrentPeerList(peers: model.connectedPeers(job.id), connected: job.peers)
                                .frame(maxWidth: 460)
                            Text("Only the file list is being fetched; file contents have not started downloading.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !job.phase.active && job.destination == nil && job.relay == nil {
                            Button("Try Loading Again") { Task { await model.resume(job.id) } }.disabled(busy)
                            Button("Use Another Link or .torrent File") { jobID = nil; loadedSelection = false; ownsJob = false }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { sourceForm; Spacer() }
            if let error = localError ?? (jobID == nil ? nil : model.error) {
                Text(error).font(.callout).foregroundStyle(.orange).lineLimit(3).help(error)
            }
            Text(toPikPak ? "Torrent → RAM → PikPak. Uploads use the selected login’s upload allowance. Completed files are recorded; lost RAM data is downloaded again." : "Downloads use this Mac’s internet connection and local disk. BitTorrent uploads pieces to peers while downloading; seeding stops at completion.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Divider()
            footer
        }.padding(24).frame(width: 720, height: job?.files.isEmpty == false ? 740 : 430)
            .interactiveDismissDisabled(busy)
            .onAppear { initialiseSelection(); if let pikpak { model.configureRelayAccount(pikpak); pikpak.preparePikPakManagement(); cloudContext = pikpak.pikpakManagement.context } }
            .onChange(of: job?.files.count) { _ in initialiseSelection() }
            .onDisappear {
                if ownsJob, let job, job.phase == .metadata { Task { await model.pause(job.id) } }
            }
    }

    private var sourceForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Magnet link").font(.callout.weight(.medium))
            TextField("magnet:?xt=urn:btih:…", text: $magnet).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Torrent magnet link")
            HStack {
                Button("Open .torrent File…", action: openTorrent)
                Spacer()
                Text("BitTorrent v1 or hybrid torrents").font(.caption).foregroundStyle(.secondary)
            }
            Text("The first step fetches only the file list. You can select individual files before starting the download.")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
        }.padding(.top, 12)
    }

    private var fileSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search files", text: $search).textFieldStyle(.roundedBorder)
                Button("Select All") { selected = Set(job?.payloadFiles.map(\.index) ?? []) }
                Button("Clear All") { selected = [] }
            }
            List(visibleFiles) { file in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { selected.contains(file.index) }, set: { value in
                        if value { selected.insert(file.index) } else { selected.remove(file.index) }
                    })) { Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path) }
                        .toggleStyle(.checkbox)
                    Spacer(minLength: 8)
                    Text(LocalTorrentFormat.bytes(file.length)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.padding(.vertical, 2)
            }.frame(maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(selected.count.formatted()) of \((job?.payloadFiles.count ?? 0).formatted()) selected")
                Spacer(); Text(LocalTorrentFormat.bytes(selectedBytes)).monospacedDigit()
            }.font(.callout.weight(.medium))
            Picker("Destination", selection: $toPikPak) {
                Text("This Mac").tag(false)
                Text("PikPak · RAM only").tag(true)
            }.pickerStyle(.segmented)
            if toPikPak {
                if let pikpak {
                    TorrentRelayDestinationView(account: pikpak, parent: $cloudParent, budget: $memoryBytes) { context in cloudContext = context }
                } else {
                    Label("Sign in to PikPak to choose a cloud destination.", systemImage: "person.crop.circle.badge.exclamationmark").font(.callout).foregroundStyle(.secondary)
                }
            } else {
            HStack {
                Text("Save to").font(.callout.weight(.medium))
                Text(destination?.path ?? "Choose a folder…").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer(); Button("Choose…", action: chooseDestination)
            }
            Text("A new folder will be created for this torrent. Small boundary pieces may be received for neighbouring files; unselected files are removed on completion.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }.disabled(busy)
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let job {
                if job.canChoose {
                    Button(toPikPak ? "Download to PikPak" : "Download to Mac") {
                        submitting = true; localError = nil
                        Task {
                            if toPikPak, let context = cloudContext {
                                await model.downloadToPikPak(job.id, selected: selected, context: context,
                                    accountName: pikpak?.accountDisplayName ?? "PikPak account", parentID: cloudParent.id,
                                    parentName: cloudParent.name, memoryBytes: memoryBytes)
                            } else if !toPikPak, let destination { await model.download(job.id, selected: selected, to: destination) }
                            submitting = false
                            if model.job(job.id)?.phase.active == true { ownsJob = false; dismiss(); onStarted() }
                        }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty || (toPikPak ? cloudContext == nil : destination == nil) || busy)
                } else {
                    Button("Show in Transfers") { ownsJob = false; dismiss(); onStarted() }
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
            } else {
                Button("Load File List") {
                    do {
                        let previous = Set(model.jobs.map(\.id)); let id = try model.add(magnet: magnet)
                        jobID = id; ownsJob = !previous.contains(id); localError = nil; initialiseSelection()
                    } catch { localError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(LocalTorrentSource.infoHash(magnet) == nil || busy)
            }
        }
    }

    private func initialiseSelection() {
        guard !loadedSelection, let job, !job.files.isEmpty else { return }
        selected = Set(job.selected); loadedSelection = true
    }
    private func openTorrent() {
        let panel = NSOpenPanel(); panel.title = "Open Torrent File"
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsOtherFileTypes = false; panel.canChooseFiles = true
        panel.canChooseDirectories = false; panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            let chosen = panel.url
            // Do not leak this filter into any later app file/folder picker.
            panel.allowedContentTypes = []; panel.allowsOtherFileTypes = true
            guard response == .OK, let url = chosen else { return }
            do { jobID = try model.add(torrent: url); ownsJob = true; loadedSelection = false; localError = nil }
            catch { localError = error.localizedDescription }
        }
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.title = "Choose Torrent Download Folder"; panel.prompt = "Choose Folder"
        // AppKit may reuse an Open panel. Clear the .torrent filter before
        // switching it to directory selection.
        panel.allowedContentTypes = []; panel.allowsOtherFileTypes = true
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = destination
        panel.begin { response in
            if response == .OK, let url = panel.url { destinationLease = LocalFileAccessLease([url]); destination = url }
        }
    }
}
