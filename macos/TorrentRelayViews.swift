import SwiftUI

struct TorrentRelayDestinationView: View {
    @ObservedObject var account: DownloaderModel
    @Binding var parent: PikPakManagedFile
    @Binding var budget: UInt64
    let contextChanged: (PikPakManagementContext?) -> Void
    @State private var choosing = false
    private var connection: String { (account.activeAccountID?.uuidString ?? "") + (account.activeSavedAccount?.credentialKind?.rawValue ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.icloud").foregroundStyle(FinderAppearance.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.accountDisplayName ?? "Sign in to PikPak").font(.callout.weight(.semibold))
                    Text(account.activeSavedAccount?.credentialKind?.loginTitle ?? "Choose an account in the sidebar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(parent.name, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                Button("Choose Folder…") { account.preparePikPakManagement(); choosing = true }
                    .disabled(account.pikpakManagement.context == nil)
            }
            HStack {
                Picker("RAM buffer", selection: $budget) {
                    ForEach(TorrentRelayState.budgets, id: \.self) { bytes in
                        Text("\(bytes / TorrentRelayState.gib) GB").tag(bytes)
                    }
                }.frame(width: 195)
                    .help("Use up to 75% of this Mac’s installed memory for the RAM buffer.")
                Spacer()
                Text("Up to \(TorrentRelayState.maximumBudget() / TorrentRelayState.gib) GB · continuously reused")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("A new torrent folder keeps the file structure. Pause keeps RAM; Stop releases it. Resume skips files already uploaded, including after an app or Mac restart.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(FinderAppearance.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .onAppear { update() }
            .onChange(of: connection) { _ in
                parent = .init(id: "", name: "My PikPak", isFolder: true, size: 0)
                update()
            }
            .sheet(isPresented: $choosing) {
                PikPakFileChooser(management: account.pikpakManagement, foldersOnly: true) { files in if let file = files.first { parent = file } }
            }
    }
    private func update() { account.preparePikPakManagement(); contextChanged(account.pikpakManagement.context) }
}

struct TorrentRelayProgress: View {
    let job: LocalTorrentJob
    let relay: TorrentRelayState
    var peers: [LocalTorrentPeer] = []
    /// The engine still holds this job's torrent, so a drain is not a pause.
    var torrentRunning = false
    var account: DownloaderModel? = nil
    /// Downloading, or uploading a finished file while the rest keeps arriving.
    private var live: Bool { job.phase == .downloading || (job.phase == .uploading && torrentRunning) }
    private var uploadProgress: Double {
        job.total == 0 ? job.progress : min(1, Double(job.completed + (relay.stage == "uploading" ? relay.currentBytes : 0)) / Double(job.total))
    }
    private var bufferLabel: String {
        if relay.storage != nil {
            return "Storage · \(LocalTorrentFormat.bytes(relay.effectiveStorageLimit)) limit\(relay.storageLimitBytes == nil ? " (automatic)" : "")"
        }
        return "RAM only · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: relay.memoryBytes), countStyle: .memory)) buffer"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            FinderTransferActionLayout {
                Label("PikPak · \(relay.accountName)", systemImage: "externaldrive.badge.icloud").lineLimit(1)
                if let account, job.phase != .completed {
                    TorrentRelayLoginMenu(account: account, relay: relay)
                } else { Text(relay.credentialKind.loginTitle).foregroundStyle(.secondary) }
                Text("\(job.savedFileCount) / \(job.selected.count) files saved").monospacedDigit()
            }.font(.caption)
            ProgressView(value: uploadProgress).progressViewStyle(.linear)
            FinderTransferActionLayout {
                Text("Saved to PikPak \(LocalTorrentFormat.percentage(job.progress)) · \(LocalTorrentFormat.bytes(job.completed)) of \(LocalTorrentFormat.bytes(job.total)) total")
                    .help("Total is the selected torrent size. Files pass through the reusable \(relay.bufferName) buffer as they upload to PikPak.")
                if job.phase == .uploading {
                    Label(LocalTorrentFormat.speed(job.relayUploadSpeed ?? 0), systemImage: "arrow.up")
                        .help("Current upload speed from \(relay.bufferName) to PikPak")
                        .accessibilityLabel("PikPak upload speed: \(LocalTorrentFormat.speed(job.relayUploadSpeed ?? 0))")
                }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let failure = relay.uploadFailure, job.phase.active {
                VStack(alignment: .leading, spacing: 3) {
                    Label("PikPak upload paused", systemImage: "icloud.slash")
                        .font(.caption.weight(.semibold))
                    Text(failure.awaitingAccount
                         ? "Sign in to \(relay.accountName) to resume uploads. Downloading continues while \(relay.bufferName) space is available."
                         : "Uploads retry automatically. Downloading continues while \(relay.bufferName) space is available.")
                    Text(failure.message).lineLimit(2).help(failure.message)
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if relay.payload != nil {
                FinderTransferActionLayout(spacing: 12) {
                    Label(bufferLabel, systemImage: relay.storage == nil ? "memorychip" : "externaldrive")
                        .help(relay.storage == nil ? "The selected RAM buffer size." : "\(LocalTorrentFormat.bytes(relay.bufferAvailable ?? 0)) available on the drive. Automatic leaves 100 GB free. Change the total torrent storage limit from the torrent’s menu while downloading.")
                    if live {
                        if let used = relay.bufferUsed {
                            Text(relay.storage == nil ? "\(LocalTorrentFormat.bytes(used)) in RAM" : "\(LocalTorrentFormat.bytes(used)) disk space used")
                                .help("Includes unfinished data and uploaded copies kept locally until cleanup. This overlaps with Saved to PikPak; the two numbers should not be added together.")
                        }
                        Label(LocalTorrentFormat.speed(job.downloadSpeed), systemImage: "arrow.down")
                            .help("Current download speed from peers")
                            .accessibilityLabel("Download speed: \(LocalTorrentFormat.speed(job.downloadSpeed))")
                        Label(LocalTorrentFormat.speed(job.uploadSpeed), systemImage: "arrow.up")
                            .help("Current upload speed to peers. Seeding continues while the torrent downloads.")
                            .accessibilityLabel("Upload speed: \(LocalTorrentFormat.speed(job.uploadSpeed))")
                        Text(LocalTorrentFormat.peerConnections(job))
                            .help("Peers that completed the BitTorrent handshake. Connection attempts that never answer are not counted.")
                    } else if job.phase == .paused { Text("Held while paused") }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if relay.storage != nil, let used = relay.bufferUsed, used > relay.effectiveStorageLimit {
                Text("Reducing disk usage to \(LocalTorrentFormat.bytes(relay.effectiveStorageLimit)). Completed files upload first; partial files are kept and may temporarily exceed the limit.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let cleanup = relay.paddingCleanup {
                if let failure = cleanup.failure {
                    Text("Padding cleanup will retry automatically. \(failure)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(failure)
                } else if !cleanup.removed.isEmpty {
                    Text("Cleaned up \(cleanup.removed.count) padding files from PikPak.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Cleanup moves matching padding files to Trash and keeps the original upload receipts.")
                }
            }
            FinderTransferActionLayout {
                Text("Downloaded overall \(LocalTorrentFormat.percentage(job.downloadProgress)) · \(LocalTorrentFormat.bytes(job.downloadedBytes)) of \(LocalTorrentFormat.bytes(job.total)) total")
                    .help("Counts downloaded data once, including files already saved to PikPak. Disk space used can also include those uploaded files and filesystem overhead.")
                Text(live && job.checkingPieces == true ? "Checking downloaded pieces" : job.downloadEstimate)
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: job.downloadProgress).progressViewStyle(.linear).tint(.secondary)
            if job.downloadedAwaitingPikPakBytes > 0 {
                Text("\(LocalTorrentFormat.bytes(job.downloadedAwaitingPikPakBytes)) downloaded, not yet saved to PikPak")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("Includes partial files. Each file uploads after its download is complete and verified.")
            }
            Text(relay.storage == nil ? "File contents stay in RAM until uploaded to PikPak. Only resume information is saved locally." :
                    relay.keepsUploadedFiles ? "Uploaded copies stay available for sharing while space allows. Space is reserved for unfinished downloads and other apps; copies are cleared as needed or when the transfer finishes." :
                    "Uploaded copies are removed once unfinished files no longer need their shared torrent pieces. Pause and Stop keep unfinished files for Resume.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LocalTorrentPeerList(peers: peers, connected: job.peers)
            Label("\(relay.parentName) / \(relay.rootName)", systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct TorrentStorageLimitSheet: View {
    @ObservedObject var model: LocalTorrentModel
    let job: LocalTorrentJob
    @Environment(\.dismiss) private var dismiss
    @State private var automatic: Bool
    @State private var gigabytes: String

    init(model: LocalTorrentModel, job: LocalTorrentJob) {
        self.model = model; self.job = job
        _automatic = State(initialValue: job.relay?.storageLimitBytes == nil)
        _gigabytes = State(initialValue: String((job.relay?.storageLimitBytes ?? 200 * TorrentRelayDrain.storageGB) / TorrentRelayDrain.storageGB))
    }
    private var customBytes: UInt64? {
        guard let count = UInt64(gigabytes.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else { return nil }
        let bytes = count.multipliedReportingOverflow(by: TorrentRelayDrain.storageGB)
        return bytes.overflow ? nil : bytes.partialValue
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Torrent Storage Limit").font(.title2.weight(.semibold))
            Text(job.name).foregroundStyle(.secondary).lineLimit(2)
            Toggle("Automatic — leave 100 GB free on the drive", isOn: $automatic)
            HStack {
                Text("Maximum disk usage")
                TextField("200", text: $gigabytes).textFieldStyle(.roundedBorder).frame(width: 100)
                    .disabled(automatic).accessibilityLabel("Torrent storage limit in GB")
                Text("GB")
            }
            if let state = model.job(job.id)?.relay {
                Text("Currently using \(LocalTorrentFormat.bytes(state.bufferUsed ?? 0)). Automatic limit: \(LocalTorrentFormat.bytes(TorrentRelayDrain.storageLimit(capacity: state.bufferCapacity, configured: nil))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Includes partial downloads and uploaded copies kept for sharing. Lowering the limit uploads completed files and clears confirmed copies first. Partial files stay intact and may temporarily keep usage above the limit.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.setStorageLimit(job.id, bytes: automatic ? nil : customBytes)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled((!automatic && customBytes == nil) || model.busy.contains(job.id) || model.job(job.id)?.phase == .completed)
            }
        }.padding(24).frame(width: 510)
    }
}

/// Reuse the existing saved-login and sign-in flow, restricted to this
/// transfer's original cloud account. No torrent engine operation is involved.
private struct TorrentRelayLoginMenu: View {
    @ObservedObject var account: DownloaderModel
    let relay: TorrentRelayState
    private var entry: SavedPikPakAccount? {
        let matches = account.savedAccounts.filter { $0.accountIdentifier == relay.accountID }
        return matches.first { $0.id == relay.identity } ?? matches.first
    }
    private var selectedKind: PikPakCredentialKind {
        account.activeSavedAccount?.accountIdentifier == relay.accountID ? account.activeCredentialKind : relay.credentialKind
    }
    var body: some View {
        Menu {
            ForEach(PikPakCredentialKind.allCases) { kind in
                Button {
                    guard let entry else { return }
                    account.selectPikPakConnection(kind, accountID: entry.id, fromSettings: false)
                } label: {
                    if selectedKind == kind { Label(kind.loginTitle, systemImage: "checkmark") }
                    else { Text(kind.loginTitle) }
                }
            }
        } label: {
            Text(account.isChangingAccount ? "Switching login…" : selectedKind.loginTitle)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(!account.canChangeAccount || entry == nil)
        .help(account.accountChangeBlockedReason ?? (entry == nil
              ? "Reconnect this torrent’s original PikPak account to change its upload login."
              : "Change this workspace’s login for the same PikPak account. Torrent downloading continues."))
        .accessibilityLabel("PikPak upload login")
        .accessibilityValue(selectedKind.loginTitle)
    }
}
