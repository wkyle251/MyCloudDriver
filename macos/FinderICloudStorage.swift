import AppKit
import SwiftUI

struct FinderICloudStorage: View {
    @ObservedObject var storage: ICloudStorageModel
    let connected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Storage").font(.caption.weight(.semibold))
                Spacer()
                Button { storage.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).pointingHandCursor().disabled(!connected || storage.isRefreshing)
                    .accessibilityLabel("Refresh iCloud storage").help("Refresh available iCloud account storage")
            }
            if !connected {
                Text("Connect iCloud Drive").font(.caption2).foregroundStyle(.secondary)
            } else if storage.isRefreshing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Checking iCloud…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let bytes = storage.remainingBytes {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)) available")
                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(FinderAppearance.accent)
                    .help(storage.checkedAt.map { "Checked \($0.formatted(date: .abbreviated, time: .standard))" } ?? "")
            } else {
                Text(storage.errorMessage == nil ? "Click to refresh" : "Storage unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(storage.errorMessage ?? "Refresh to check available iCloud storage")
            }
            Text("Personal iCloud account").font(.caption2).foregroundStyle(.secondary)
                .help("Account storage is shared by iCloud Drive, Photos, backups and other iCloud data. This is not local disk space.")
            Button("Storage Settings…", action: openICloudStorageSettings)
                .font(.caption2).buttonStyle(.borderless).pointingHandCursor()
                .help("View your iCloud plan, total capacity and usage breakdown in System Settings")
        }.padding(12)
            .onAppear { if connected { storage.refresh() } }
            .onChange(of: connected) { if $0 { storage.refresh() } else { storage.clear() } }
    }
}

struct FinderICloudStorageSettings: View {
    @ObservedObject var storage: ICloudStorageModel
    let connected: Bool
    var body: some View {
        LabeledContent("Personal iCloud storage") {
            if storage.isRefreshing { ProgressView().controlSize(.small) }
            else if let bytes = storage.remainingBytes, connected {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)) available").monospacedDigit()
            } else { Text(connected ? "Unavailable" : "Connect to check").foregroundStyle(.secondary) }
            Button { storage.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .disabled(!connected || storage.isRefreshing).help("Refresh iCloud storage")
        }
        if let error = storage.errorMessage, connected {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
        }
        Button("iCloud Storage Settings…", action: openICloudStorageSettings)
        Text("macOS reports available account space here. View your plan capacity and usage breakdown in iCloud Storage settings.")
            .font(.caption).foregroundStyle(.secondary)
            .onAppear { if connected { storage.refresh() } }
    }
}

func openICloudStorageSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud")!
    if !NSWorkspace.shared.open(url) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
