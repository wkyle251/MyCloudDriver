import SwiftUI

/// Warn as a volume fills: orange from 80% and red from 95%. Shared by PikPak and local storage bars.
func storageUsageColor(for fraction: Double) -> Color {
    if fraction >= 0.95 { return .red }
    if fraction >= 0.8 { return .orange }
    return Color(red: 0.96, green: 0.72, blue: 0.28)
}

/// Sidebar capacity for the volume behind a chosen folder or external disk, laid out like the PikPak block.
struct FinderLocalStorage: View {
    @ObservedObject var storage: LocalVolumeStorageModel
    let rootURL: URL?
    let connected: Bool
    let message: String?
    let busy: Bool
    let choose: () -> Void

    /// Decimal units match Finder, Disk Utility and the capacity printed on the disk itself.
    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Storage").font(.caption.weight(.semibold))
                Spacer()
                Button { storage.refresh(for: rootURL) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).pointingHandCursor().disabled(rootURL == nil || storage.isRefreshing)
                    .accessibilityLabel("Refresh disk storage").help("Refresh used and available space on this disk")
            }
            if let capacity = storage.capacity {
                ProgressView(value: capacity.usedFraction).tint(storageUsageColor(for: capacity.usedFraction))
                Text("\(Self.format(capacity.used)) / \(Self.format(capacity.total))")
                    .font(.caption2).monospacedDigit()
                Text("\(Self.format(capacity.available)) available").font(.caption2).foregroundStyle(.secondary)
                    .help(storage.checkedAt.map { "Checked \($0.formatted(date: .abbreviated, time: .standard))" } ?? "")
                Text(capacity.name.map { "Disk: \($0)" } ?? "Selected disk or network share")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help("Space is for the whole disk that holds the chosen folder")
            } else if storage.isRefreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Checking disk…").font(.caption2).foregroundStyle(.secondary)
                }
                Text("Selected disk or network share").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(connected ? "Capacity unavailable" : "Connect to get started")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Selected disk or network share").font(.caption2).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            Text(rootURL?.path ?? "Choose a folder").font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
            Button("Choose Folder or Disk…", action: choose).font(.caption).disabled(busy)
        }.padding(12)
            // `.task(id:)` runs on appear and again for a new root, and sees the current value.
            .task(id: rootURL) { storage.refresh(for: rootURL) }
    }
}
