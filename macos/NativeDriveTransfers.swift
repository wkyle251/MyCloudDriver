import AppKit
import SwiftUI

/// Maintenance and preview jobs stay in Status. Transfer direction is recorded
/// when a job starts, never guessed from its translated title or current tab.
struct NativeTransferSnapshot {
    let records: [CloudDriveActivityRecord]
    init(records: [CloudDriveActivityRecord], direction: Int) {
        self.records = records.filter { $0.transferDirection == direction }
    }
    var active: [CloudDriveActivityRecord] { records.filter { $0.active && $0.state != "Paused" && $0.state != "Queued" } }
    var queued: [CloudDriveActivityRecord] { records.filter { $0.state == "Paused" || $0.state == "Queued" } }
    var completed: [CloudDriveActivityRecord] { records.filter { $0.state == "Completed" } }
    var failed: [CloudDriveActivityRecord] { records.filter { $0.state == "Failed" || $0.state == "Cancelled" } }
    var current: CloudDriveActivityRecord? { active.last ?? records.last }
    var fraction: Double? {
        guard let current else { return 0 }
        if !current.active { return current.state == "Completed" ? 1 : nil }
        if let value = current.progress.fraction, value.isFinite { return min(1, max(0, value)) }
        if current.progress.total > 0 {
            return min(1, max(0, Double(current.progress.completed) / Double(current.progress.total)))
        }
        return nil
    }
}

struct NativeDriveTransfers: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var store: CloudDriveActivityStore
    @Binding var direction: Int
    let showBrowser: () -> Void
    let showStatus: () -> Void
    var pikpak: DownloaderModel? = nil
    @State private var downloadDestination: URL?
    private var upload: Bool { direction == 1 }
    private var snapshot: NativeTransferSnapshot { .init(records: store.records, direction: direction) }
    private var destination: URL? { downloadDestination ?? model.lastExportDestination }
    private var path: String {
        upload ? model.location.url?.path ?? model.location.title : destination?.path ?? "Choose a folder on this Mac"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FinderTransferHeader(direction: $direction, destination: direction == 2 ? "BitTorrent → This Mac or PikPak" : path)
            FinderTransferCanvas {
                if direction == 2 { LocalTorrentWorkspace(pikpak: pikpak) }
                else {
                FinderTransferWorkspace {
                    FinderTransferOverview { setup } progress: { dashboard }
                    controls.finderCard(padding: 11)
                    board
                }
                }
            }
            if direction != 2 {
            HStack {
                Button(action: showStatus) { Label("Activity Log", systemImage: "list.bullet.rectangle") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("\(model.kind.title) · Transfers continue while you browse")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 4)
            }
        }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(upload ? "Upload setup" : "Download setup", systemImage: upload ? "arrow.up.doc.fill" : "arrow.down.doc.fill").font(.headline)
                Spacer()
                Text(upload ? "This Mac → \(model.kind.title)" : "\(model.kind.title) → This Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Label("Destination", systemImage: upload ? "cloud.fill" : "externaldrive.fill").frame(width: 110, alignment: .trailing)
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(path)
                        Button("Choose…") { if upload { showBrowser() } else { chooseDestination() } }
                            .disabled(!model.isConnected)
                    }
                }
                GridRow {
                    Label("Sources", systemImage: "doc.on.doc.fill").frame(width: 110, alignment: .trailing)
                    HStack {
                        Button("Choose…") { if upload { model.chooseImport() } else { showBrowser() } }
                            .disabled(!model.isConnected || (upload && model.isMutating))
                        Text(upload ? "Select files, folders, or both" : "\(model.selection.count.formatted()) items selected in Browser")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Label("Preparation", systemImage: "number.circle.fill").frame(width: 110, alignment: .trailing)
                    Text(upload
                         ? "Selected content is imported into the current \(model.kind.containerName.lowercased()). Transfers start after you choose files."
                         : "Selected folders include their contents. Cloud originals are fetched as needed and saved to your chosen folder.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Label("Service", systemImage: "network").frame(width: 110, alignment: .trailing)
                    Text("Transfers retry automatically. Pause keeps progress; Cancel removes incomplete copies.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.finderCard(padding: 14)
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(FinderAppearance.accent).frame(width: 34, height: 34)
                    .background(FinderAppearance.accent.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(upload ? "Upload progress" : "Download progress").font(.headline)
                    Text(snapshot.current?.progress.message ?? "Ready").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(snapshot.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(FinderAppearance.accent)
            }
            ProgressView(value: snapshot.fraction).progressViewStyle(.linear)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    metric("Current task", (snapshot.current?.progress.bytes ?? 0) > 0
                        ? ByteCountFormatter.string(fromByteCount: Int64(clamping: snapshot.current!.progress.bytes), countStyle: .file) : "—", "doc")
                    metric("Speed", "Not reported", "speedometer")
                }
                GridRow {
                    metric("Tasks", "\(snapshot.completed.count) / \(snapshot.records.count)", "doc.on.doc")
                    metric("Remaining", "Not reported", "clock")
                }
            }
        }.finderCard(padding: 14)
    }
    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var controls: some View {
        FinderTransferActionLayout {
            Button {
                if upload { model.chooseImport() }
                else if let destination { model.export(model.selectedItems, to: destination) }
                else { model.chooseExport(model.selectedItems) }
            } label: { Label(upload ? "Choose Files or Folders…" : "Start Download", systemImage: upload ? "arrow.up.circle" : "arrow.down.circle") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected || (upload ? model.isMutating : model.selection.isEmpty))
            Button { (snapshot.active + snapshot.queued).forEach { model.pauseTransfer($0.id) } } label: {
                Label("Pause All", systemImage: "pause.circle")
            }.disabled(snapshot.active.isEmpty)
            Button { snapshot.queued.forEach { model.resumeTransfer($0.id) } } label: {
                Label("Resume", systemImage: "play.circle")
            }.disabled(snapshot.queued.isEmpty)
            Button(role: .destructive) { (snapshot.active + snapshot.queued).forEach { model.cancel($0.id) } } label: {
                Label(upload ? "Cancel Upload" : "Cancel Download", systemImage: "stop.circle")
            }.disabled(snapshot.active.isEmpty && snapshot.queued.isEmpty)
            Button(action: showBrowser) { Label("Show Cloud Folder", systemImage: "folder") }
        }
    }
    private var board: some View {
        FinderTransferBoardLayout(finishedMinimumHeight: snapshot.failed.isEmpty ? 210 : 330) {
            lane(upload ? "Uploading" : "Downloading", upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill", .blue,
                snapshot.active, empty: upload ? "No active uploads" : "No active downloads")
            lane("Queue", "text.line.first.and.arrowtriangle.forward", .orange, snapshot.queued, empty: "Waiting and paused transfers appear here")
            VStack(spacing: 12) {
                lane("Completed", "checkmark.circle.fill", .green, Array(snapshot.completed.reversed()), empty: "Completed transfers appear here")
                    .frame(minHeight: 160)
                    .layoutPriority(1)
                if !snapshot.failed.isEmpty {
                    lane("Failed / Cancelled", "exclamationmark.triangle.fill", .red, Array(snapshot.failed.reversed()), empty: "")
                        .frame(minHeight: 140, idealHeight: 195, maxHeight: 235)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func lane(_ title: String, _ symbol: String, _ color: Color, _ records: [CloudDriveActivityRecord], empty: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                Text(title).font(.headline); Spacer()
                Text(records.count.formatted()).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
            }.padding(.horizontal, 13).padding(.vertical, 11)
            Divider()
            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text(empty).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(record.title).font(.callout.weight(.medium)); Spacer(); Text(record.state).font(.caption).foregroundStyle(.secondary) }
                                Text(record.progress.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                if record.active {
                                    ProgressView(value: NativeTransferSnapshot(records: [record], direction: direction).fraction)
                                    HStack {
                                        Button(record.state == "Paused" ? "Resume" : "Pause") {
                                            if record.state == "Paused" { model.resumeTransfer(record.id) } else { model.pauseTransfer(record.id) }
                                        }.disabled(record.state == "Stopping")
                                        Spacer()
                                        Button("Cancel", role: .destructive) { model.cancel(record.id) }.disabled(record.state == "Stopping")
                                    }.buttonStyle(.borderless).pointingHandCursor()
                                }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(10)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).finderCard(padding: 0)
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.title = "Download Destination"; panel.prompt = "Choose Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.begin { response in if response == .OK { downloadDestination = panel.url } }
    }
}
