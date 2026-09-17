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
                Text("Up to \(TorrentRelayState.maximumBudget() / TorrentRelayState.gib) GB · reused between batches")
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
    private var uploadProgress: Double {
        job.total == 0 ? job.progress : min(1, Double(job.completed + (relay.stage == "uploading" ? relay.currentBytes : 0)) / Double(job.total))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("PikPak · \(relay.accountName)", systemImage: "externaldrive.badge.icloud").lineLimit(1)
                Text(relay.credentialKind.loginTitle).foregroundStyle(.secondary)
                Spacer()
                Text("\(relay.uploaded.count) / \(job.selected.count) files saved").monospacedDigit()
            }.font(.caption)
            ProgressView(value: uploadProgress).progressViewStyle(.linear)
            HStack {
                Text("\(LocalTorrentFormat.bytes(job.completed)) of \(LocalTorrentFormat.bytes(job.total)) saved to PikPak")
                Spacer()
                if job.phase == .uploading { Label(LocalTorrentFormat.speed(job.uploadSpeed), systemImage: "arrow.up") }
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if relay.volume != nil {
                HStack(spacing: 12) {
                    Label("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: relay.memoryBytes), countStyle: .memory)) RAM buffer", systemImage: "memorychip")
                    if job.phase == .downloading {
                        Text("\(LocalTorrentFormat.bytes(relay.batchDownloaded)) / \(LocalTorrentFormat.bytes(relay.batchTotal))")
                        Label(LocalTorrentFormat.speed(job.downloadSpeed), systemImage: "arrow.down")
                        Text(job.peers == 1 ? "1 peer" : "\(job.peers) peers")
                            .help("Peers that completed the BitTorrent handshake. Connection attempts that never answer are not counted.")
                        if let drained = relay.drained, !drained.isEmpty {
                            Text("\(drained.count) freed from RAM")
                                .help("Files already saved to PikPak whose memory has been returned. They are not downloaded again.")
                        }
                    } else if job.phase == .paused { Text("Held while paused") }
                    Spacer()
                    Text("Batch \(min(relay.batch + 1, relay.batches.count)) / \(relay.batches.count)")
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if job.phase == .downloading {
                    ProgressView(value: relay.batchTotal == 0 ? 0 : min(1, Double(relay.batchDownloaded) / Double(relay.batchTotal)))
                        .progressViewStyle(.linear).tint(.secondary)
                }
            }
            Label("\(relay.parentName) / \(relay.rootName)", systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}
