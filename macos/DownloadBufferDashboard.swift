import SwiftUI

/// Numeric transfer state only; no download names or paths are needed here.
struct DownloadBufferDashboard: View {
    let usage: DownloadBufferUsage?
    let isDownloading: Bool
    var isPaused: Bool = false
    let configuredLimit: UInt64
    let destination: URL
    @StateObject private var diskRates = DownloadDiskRateMonitor()

    private var used: UInt64 { isDownloading ? usage?.used ?? 0 : 0 }
    private var configured: UInt64 { usage?.configured ?? configuredLimit }
    private var limit: UInt64 { usage?.limit ?? configured }
    private var pressure: UInt64 { usage?.pressure ?? 1 }
    private var status: String {
        !isDownloading ? "Idle" : isPaused ? (used > 0 ? "Paused · saving buffer" : "Reception paused") : pressure >= 4 ? "Draining for memory"
            : pressure >= 2 ? "Memory pressure"
            : used > 0 ? "Receiving ahead of disk"
            : (usage?.traffic?.activeReadTasks ?? 0) > 0 || (usage?.traffic?.finalVerificationTasks ?? 0) > 0
                ? "Verifying saved downloads" : "Ready to receive"
    }
    private var statusColor: Color { pressure >= 2 ? .orange : isDownloading ? .blue : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { heading; Spacer(minLength: 8); amount; statusBadge }
                VStack(alignment: .leading, spacing: 9) {
                    HStack { heading; Spacer(); statusBadge }
                    amount
                }
            }
            ProgressView(value: min(Double(used), Double(limit)), total: max(1, Double(limit)))
                .progressViewStyle(.linear).tint(statusColor)
                .accessibilityLabel("Download RAM buffer usage")
            if isDownloading, let traffic = usage?.traffic {
                if let bytes = traffic.prefetchBytes, bytes > 0 {
                    Text("Awaiting saved-data checks: \(DownloadBufferPolicy.text(bytes)) · \(traffic.prefetchTasks ?? 0) transfers")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help("Receiving continues into the shared RAM buffer. These bytes become writable after the saved prefix passes validation.")
                }
                Divider()
                turn(traffic)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { readPools(traffic); writePools(traffic) }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { readPools(traffic) }
                        HStack(spacing: 8) { writePools(traffic) }
                    }
                    VStack(spacing: 8) { readPools(traffic); writePools(traffic) }
                }
                diskSpeeds
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { diskStatus(traffic); oldestWait(traffic); Spacer(); peak }
                    VStack(alignment: .leading, spacing: 5) { diskStatus(traffic); HStack { oldestWait(traffic); Spacer(); peak } }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                diskSpeeds
            }
        }
        .task(id: destination) { await diskRates.watch(destination: destination) }
    }

    private var heading: some View {
        Label("RAM buffer", systemImage: "memorychip").font(.headline)
            .help("Cloud → RAM → Disk. Pause stops cloud reception while buffered writes and verification continue. Normal Quit saves the buffer to disk before closing. Adjust the buffer limit in Settings → General.")
    }
    private var amount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(DownloadBufferPolicy.text(used)).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("/ \(DownloadBufferPolicy.text(limit))").font(.callout).foregroundStyle(.secondary)
        }.monospacedDigit()
        .help("Maximum: \(DownloadBufferPolicy.text(configured)). The current allowance grows as needed and falls under macOS memory pressure. Selecting a write batch keeps its data in this RAM buffer until the writer consumes it.")
    }
    private var statusBadge: some View {
        Text(status).font(.caption.weight(.medium)).foregroundStyle(statusColor)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(statusColor.opacity(0.09), in: Capsule())
    }
    private var peak: some View { Text("Peak \(DownloadBufferPolicy.text(usage?.peak ?? 0))") }

    private var diskSpeeds: some View {
        HStack(spacing: 18) {
            Label("Disk read \(TaskDiskRate.text(diskRates.usage?.readBytesPerSecond))", systemImage: "arrow.up.doc")
                .foregroundStyle(.purple)
            Label("Disk write \(TaskDiskRate.text(diskRates.usage?.writtenBytesPerSecond))", systemImage: "arrow.down.doc")
                .foregroundStyle(.blue)
        }
        .font(.caption.weight(.medium)).monospacedDigit()
        .help("Physical destination disk activity, including other apps, refreshed every 2 seconds. Network shares and unavailable counters show —. No download files are scanned.")
    }

    private func turn(_ traffic: DownloadDiskTraffic) -> some View {
        let reading = traffic.readDrives > 0
        let color: Color = reading ? .purple : .blue
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(reading && traffic.writeDrives > 0 ? "Read/write turns on separate disks" : reading ? "Read turn" : "Write turn")
                .font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Spacer(minLength: 4)
            if let wait = traffic.switchWaitMs, wait > 0 {
                Text("Finishing I/O · \(wait / 1_000)s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if let turn = traffic.turnSummary {
                Text(turn).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
    @ViewBuilder private func readPools(_ traffic: DownloadDiskTraffic) -> some View {
        pool("Checks waiting", bytes: traffic.waitingCheckBytes, symbol: "clock",
             detail: "\(traffic.waitingCheckCount.formatted()) checks queued", color: .purple, selected: false)
            .help("Checks waiting for disk I/O, including checks selected for the current turn that have not started reading.")
        pool("Reading now", bytes: traffic.activeReadBytes ?? 0, symbol: "doc.text.magnifyingglass",
             detail: (traffic.activeReadTasks ?? 0) == 1 ? "1 active read" : "\((traffic.activeReadTasks ?? 0).formatted()) active reads",
             color: .purple, selected: (traffic.activeReadTasks ?? 0) > 0)
            .help("Remaining bytes in checks currently performing disk I/O. Other checks stay in Checks waiting until the disk reads them.")
    }
    @ViewBuilder private func writePools(_ traffic: DownloadDiskTraffic) -> some View {
        pool("Pending writes", bytes: traffic.pendingWriteBytes ?? 0, symbol: "tray.and.arrow.down",
             detail: "Waiting for a disk turn", color: .blue, selected: false)
        pool("Writing", bytes: traffic.writingBytes ?? 0, symbol: "externaldrive",
             detail: "\((traffic.writingTasks ?? 0).formatted()) transfers in turn", color: .blue, selected: traffic.writeDrives > 0)
    }
    private func pool(_ title: String, bytes: UInt64, symbol: String, detail: String, color: Color, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium))
                .foregroundStyle(selected ? color : .secondary).lineLimit(1)
            Text(DownloadBufferPolicy.text(bytes)).font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary).monospacedDigit().lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 124, maxWidth: .infinity, alignment: .leading).padding(11)
        .background(selected ? color.opacity(0.07) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? color.opacity(0.18) : Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
    private func diskStatus(_ traffic: DownloadDiskTraffic) -> some View {
        Text("Disk I/O: \(traffic.activeReadTasks ?? 0) reading · \(traffic.activeWriteTasks ?? 0) writing")
    }
    @ViewBuilder private func oldestWait(_ traffic: DownloadDiskTraffic) -> some View {
        if traffic.waitingCheckCount > 0, let wait = traffic.oldestWaitingReadMs ?? traffic.oldestPendingMs {
            Text("Oldest read wait \(wait / 1_000)s").foregroundStyle(wait >= 60_000 ? Color.orange : .secondary)
        } else if let ready = traffic.readyReadTasks, ready > 0 {
            Text("\(ready) reads ready for disk")
        }
    }
}
