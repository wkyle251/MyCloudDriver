import SwiftUI

struct NativeDiskTrashView: View {
    @ObservedObject var model: NativeDriveModel
    @State private var confirmsEmpty = false
    @State private var pendingEmpty: Set<UUID> = []
    private var canChange: Bool { model.isConnected && model.diskTrashReady && !model.isMutating && !model.diskTrashLoading }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Label("Trash", systemImage: "trash").font(.title2.weight(.semibold))
                Spacer()
                if model.diskTrashLoading || model.isMutating { ProgressView().controlSize(.small) }
                Button("Put Back") { model.putBackFromDiskTrash(model.diskTrashSelection) }
                    .disabled(!canChange || model.diskTrashSelection.isEmpty)
                    .help("Restore selected items to their original locations")
                Button("Empty Trash…", role: .destructive) {
                    pendingEmpty = Set(model.diskTrashItems.map(\.id)); confirmsEmpty = true
                }.disabled(!canChange || model.diskTrashItems.isEmpty)
                Button { model.refreshDiskTrash(prepare: true) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isMutating || model.diskTrashLoading).help("Refresh Trash")
            }.finderCard(padding: 12)
            Text("Deleted items stay on this disk until you put them back or empty Trash.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let error = model.diskTrashError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.diskTrashItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text(model.diskTrashLoading ? "Loading Trash…" : "Trash is empty").font(.title3.weight(.semibold))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).finderCard(padding: 16)
            } else {
                Table(model.diskTrashItems, selection: $model.diskTrashSelection) {
                    TableColumn("Name") { item in
                        Label(item.name, systemImage: item.isFolder ? "folder.fill" : "doc")
                            .lineLimit(1).help(item.name)
                    }.width(min: 140, ideal: 240)
                    TableColumn("Original Location") { item in Text(item.originalPath).lineLimit(1).truncationMode(.middle).help(item.originalPath) }
                    TableColumn("Date Deleted") { item in Text(item.deletedAt, format: .dateTime.year().month().day().hour().minute()) }
                        .width(min: 140, ideal: 170)
                    TableColumn("Size") { item in
                        Text(item.bytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—")
                    }.width(min: 70, ideal: 90)
                }
                .contextMenu {
                    Button("Put Back") { model.putBackFromDiskTrash(model.diskTrashSelection) }
                        .disabled(!canChange || model.diskTrashSelection.isEmpty)
                }
                .accessibilityIdentifier("MyCloudDriver.diskTrash.items")
            }
        }
        .onAppear { model.refreshDiskTrash(prepare: true) }
        .confirmationDialog("Permanently empty this disk’s Trash?", isPresented: $confirmsEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { model.emptyDiskTrash(pendingEmpty); pendingEmpty = [] }
            Button("Cancel", role: .cancel) { pendingEmpty = [] }
        } message: {
            Text("Permanently delete \(pendingEmpty.count) item(s) from this disk’s Trash? This cannot be undone.")
        }
    }
}
