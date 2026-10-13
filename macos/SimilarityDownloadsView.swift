import SwiftUI

struct SimilarityDownload: Identifiable, Codable {
    let id: UInt64
    let name: String
    let received: UInt64
    let total: UInt64
    let speed: Double
    let state: String
    let attempt: UInt64
    let retrySeconds: UInt64
    var isPhotosRequest: Bool? = nil
    var providerFraction: Double? = nil

    init?(event: [String: Any]) {
        guard let name = event["name"] as? String,
              let number = event["id"] as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        id = number.uint64Value; self.name = name
        received = Self.count(event["received"]); total = Self.count(event["total"])
        let rate = (event["speed"] as? NSNumber)?.doubleValue ?? 0
        speed = rate.isFinite ? max(0, rate) : 0
        state = event["state"] as? String ?? "connecting"
        attempt = Self.count(event["attempt"]); retrySeconds = Self.count(event["retry_seconds"])
    }
    static func count(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else { return 0 }
        return number.uint64Value
    }
    var fraction: Double? {
        if isPhotosRequest == true && received == 0 { return providerFraction }
        return total > 0 ? min(1, Double(received) / Double(total)) : nil
    }
    var byteLabel: String {
        if isPhotosRequest == true && received == 0 {
            return providerFraction.map { "\(Int($0 * 100))% from iCloud" } ?? "Not received yet"
        }
        return total > 0 ? "\(SimilarityScanProgress.bytes(received)) / \(SimilarityScanProgress.bytes(total))"
            : "\(SimilarityScanProgress.bytes(received)) received"
    }
    func currentSpeed(age: TimeInterval, running: Bool) -> Double {
        running && state == "downloading" && age < 5 ? speed : 0
    }
    static func speedLabel(_ rate: Double) -> String {
        guard rate.isFinite, rate >= 1 else { return "—" }
        return SimilarityScanProgress.bytes(UInt64(min(rate, Double(Int64.max)))) + "/s"
    }
    func remainingLabel(speed: Double) -> String {
        guard total > received, speed >= 1 else { return "—" }
        let seconds = Double(total - received) / speed
        guard seconds < 604_800 else { return "> 7 days" }
        let rounded = max(1, Int(seconds.rounded(.up)))
        if rounded >= 3600 { return "\(rounded / 3600)h \(rounded % 3600 / 60)m" }
        if rounded >= 60 { return "\(rounded / 60)m \(rounded % 60)s" }
        return "\(rounded)s"
    }
    func status(age: TimeInterval, running: Bool) -> String {
        guard running else { return "Paused" }
        switch state {
        case "waiting_memory": return "Waiting for RAM"
        case "queued": return "Waiting to connect"
        case "retrying":
            let remaining = max(0, Int(clamping: retrySeconds) - Int(max(0, age)))
            return remaining > 0 ? "Retrying in \(remaining)s" : "Retrying…"
        case "downloading":
            if isPhotosRequest == true {
                if received > 0 { return age < 5 ? "Reading into RAM" : "Waiting for Photos" }
                return providerFraction == nil ? "Waiting for Photos" : "Fetching from iCloud"
            }
            return age < 5 ? "Downloading" : "Waiting for an update…"
        default: return "Connecting…"
        }
    }
}

/// Fractions describe PhotoKit preparation, not measured network bytes. A new
/// pipe attempt replaces the old token so late callbacks cannot rewind it.
struct SimilarityProviderProgress {
    private struct Pending { let attempt: UUID; var fraction: Double? }
    private var pending: [UInt64: Pending] = [:]
    mutating func begin(_ id: UInt64, attempt: UUID) { pending[id] = Pending(attempt: attempt) }
    mutating func update(_ id: UInt64, attempt: UUID, fraction: Double?) {
        guard pending[id]?.attempt == attempt, let fraction, fraction.isFinite else { return }
        let updated = max(pending[id]?.fraction ?? 0, min(1, max(0, fraction)))
        pending[id]?.fraction = updated
    }
    mutating func end(_ id: UInt64, attempt: UUID) {
        if pending[id]?.attempt == attempt { pending[id] = nil }
    }
    func apply(to downloads: inout [SimilarityDownload], photos: Bool) {
        for index in downloads.indices {
            downloads[index].isPhotosRequest = photos ? true : nil
            downloads[index].providerFraction = photos ? pending[downloads[index].id]?.fraction : nil
        }
    }
}

/// Bounded list inside the scan's scrollable progress page. Updates never
/// rebuild the Browser or expand the scan window to fit a large cloud queue.
struct SimilarityDownloadsView: View {
    let progress: SimilarityScanProgress
    let running: Bool
    @Binding var expanded: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = max(0, context.date.timeIntervalSince(progress.downloadsUpdatedAt))
            let speed = running && age < 5 ? progress.downloadSpeed : 0
            VStack(spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                        Label("Downloads to RAM", systemImage: "arrow.down.circle")
                            .font(.callout.weight(.semibold))
                        Text("\(progress.downloadCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(SimilarityDownload.speedLabel(speed)).font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(FinderAppearance.accent)
                    }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse download list" : "Expand download list")
                    .accessibilityValue("\(progress.downloadCount) files, \(SimilarityDownload.speedLabel(speed))")
                if expanded {
                    Divider()
                    HStack {
                        Text("File").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Downloaded").frame(width: 160, alignment: .trailing)
                        Text("Speed").frame(width: 100, alignment: .trailing)
                        Text("Remaining").frame(width: 85, alignment: .trailing)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 13).padding(.vertical, 8)
                    if progress.downloads.isEmpty {
                        Text("Downloads appear here as files are found. Completed originals move to analysis.")
                            .font(.callout).foregroundStyle(.secondary).padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                            LazyVStack(spacing: 0) {
                                ForEach(progress.downloads) { download in
                                    row(download, age: age)
                                    if download.id != progress.downloads.last?.id { Divider().padding(.horizontal, 13) }
                                }
                            }
                    }
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "memorychip")
                        if progress.downloadForecastSeconds > 0 {
                            Text("\(SimilarityScanProgress.memoryGB(progress.downloadForecastBytes)) projected over the next \(Int(progress.downloadForecastSeconds)) seconds · \(SimilarityScanProgress.memoryGB(progress.originalMemoryLimit)) limit")
                        } else {
                            Text("Complete originals move to Analysis RAM before hashing.")
                        }
                        Spacer(minLength: 0)
                        if progress.omittedDownloads > 0 { Text("+\(progress.omittedDownloads) waiting") }
                    }.font(.caption).foregroundStyle(.secondary).padding(12)
                        .help("New downloads use recent speed and remaining size to predict RAM growth. Receive windows also enforce the buffer limit if speeds change.")
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.10)))
        }
    }
    private func row(_ download: SimilarityDownload, age: TimeInterval) -> some View {
        let speed = download.currentSpeed(age: age, running: running)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(download.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(download.name)
                    Spacer(minLength: 0)
                    Text(download.status(age: age, running: running)).font(.caption)
                        .foregroundStyle(download.state == "retrying" ? Color.orange : Color.secondary)
                }
                if let fraction = download.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                        .accessibilityLabel("\(download.name): \(Int(fraction * 100)) percent downloaded")
                } else {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel("Downloading \(download.name); size unknown")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(download.byteLabel).frame(width: 160, alignment: .trailing)
            Text(SimilarityDownload.speedLabel(speed)).frame(width: 100, alignment: .trailing)
            Text(download.remainingLabel(speed: speed)).foregroundStyle(.secondary).frame(width: 85, alignment: .trailing)
        }.font(.caption.monospacedDigit()).padding(.horizontal, 13).frame(height: 62)
    }
}
