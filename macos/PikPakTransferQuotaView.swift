import SwiftUI

struct PikPakTransferQuotaSidebar: View {
    @ObservedObject var model: DownloaderModel
    @ObservedObject var monitor: PikPakTransferQuotaMonitor
    @State private var showsDetails = false

    private var counters: PikPakTrafficCounters {
        monitor.snapshot?.transfer.counters(for: model.activeCredentialKind) ?? .unavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.vertical, 3)
            Button { showsDetails = true } label: {
                HStack {
                    Text("Monthly quota").font(.caption.weight(.semibold))
                    Spacer()
                    Image(nsImage: FinderSymbolImage.template(named: "info.circle", style: .menu))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor()
                .help("Compare full account and Connected Apps limits")
                .accessibilityLabel("Transfer quota details")
                .sheet(isPresented: $showsDetails) {
                    PikPakTransferQuotaDetails(monitor: monitor, accountName: model.accountDisplayName ?? "PikPak account",
                                               credentialKind: model.activeCredentialKind) {
                        Task { await model.refreshTransferQuota(force: true) }
                    }
                }
            Text(model.activeCredentialKind.quotaTitle).font(.system(size: 10, weight: .medium))
                .foregroundStyle(FinderAppearance.accent)
            compactRow("Cloud download", quota: counters.cloudDownload)
            compactRow("Downstream", quota: counters.downstream)
            compactRow("Upload", quota: counters.upload)
            if let daily = counters.dailyDownstream, daily.total > 0 {
                compactRow("Downstream · daily", quota: daily)
            }
            if monitor.error != nil {
                Text("Refresh failed · view details").font(.caption2).foregroundStyle(.orange)
            }
        }
        .task(id: model.activeAccountID) {
            while !Task.isCancelled {
                await model.refreshTransferQuota()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
            }
        }
    }

    private func compactRow(_ title: String, quota: StorageQuota?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            if let quota {
                Text("\(pikpakTrafficBytes(quota.used)) / \(pikpakTrafficBytes(quota.total))")
                    .font(.system(size: 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.09))
                        .overlay(alignment: .leading) {
                            Capsule().fill(pikpakTrafficColor(quota)).frame(width: geometry.size.width * quota.usedFraction)
                        }
                }.frame(height: 4).accessibilityHidden(true)
            } else {
                Text(monitor.isRefreshing ? "Loading…" : "Unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
            .help("\(title) · used / limit · \(model.activeCredentialKind.quotaTitle)")
    }
}

struct PikPakTransferQuotaDetails: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: PikPakTransferQuotaMonitor
    let accountName: String
    var credentialKind: PikPakCredentialKind = .desktopOAuth
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Monthly transfer quota").font(.title3.weight(.semibold))
                    Text("\(accountName) · \(credentialKind.loginTitle)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if monitor.isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing quotas") }
                Button("Refresh", action: refresh).disabled(monitor.isRefreshing)
                Button { dismiss() } label: { Image(nsImage: FinderSymbolImage.template(named: "xmark", style: .menu)) }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .help("Close transfer quotas").accessibilityLabel("Close transfer quotas")
            }
            PikPakQuotaComparison(transfer: monitor.snapshot?.transfer, activeKind: credentialKind, isRefreshing: monitor.isRefreshing)
            Text("Connected Apps share a 25% limit across all personal tokens and other connected apps. This is part of the account allowance. Switching login methods does not reset usage.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Cloud download: internet → PikPak. Downstream: PikPak → your Mac, including previews and scans. Upload: your Mac → PikPak.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Counters come from PikPak and refresh every minute while visible. PikPak may report usage with a delay.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = monitor.error {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let updated = monitor.updatedAt {
                    Text("Last updated \(updated.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Monthly quotas reset each calendar month.").foregroundStyle(.secondary)
                    Spacer()
                    Link("View in PikPak", destination: URL(string: "https://mypikpak.com/drive/all?action=show_traffic_dialog")!)
                }
            }.font(.caption)
        }.padding(22).frame(width: 660)
    }
}

/// Reused by quota details and Account Settings, so both show the same scope,
/// binary units, missing-data states and actual server limits.
struct PikPakQuotaComparison: View {
    let transfer: PikPakTransferQuota?
    let activeKind: PikPakCredentialKind
    var isRefreshing = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(PikPakCredentialKind.allCases) { kind in
                scopeCard(kind)
            }
        }
    }

    private func scopeCard(_ kind: PikPakCredentialKind) -> some View {
        let counters = transfer?.counters(for: kind) ?? .unavailable
        let selected = activeKind == kind
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(nsImage: FinderSymbolImage.template(named: kind.symbol, style: .menu))
                    Text(kind.loginTitle).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(selected ? "Active" : " ").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FinderAppearance.accent)
                }
                Text(kind.quotaTitle).font(.caption).foregroundStyle(.secondary)
            }
            quotaRow("Cloud download", quota: counters.cloudDownload)
            quotaRow("Downstream", quota: counters.downstream)
            quotaRow("Upload", quota: counters.upload)
            if let daily = counters.dailyDownstream, daily.total > 0 {
                quotaRow("Downstream · daily", quota: daily)
                Text("Daily limit resets at 00:00 Singapore time.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(selected ? FinderAppearance.accent.opacity(0.055) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? FinderAppearance.accent.opacity(0.4) : Color.primary.opacity(0.1)) }
    }

    private func quotaRow(_ title: String, quota: StorageQuota?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let quota {
                Text("\(pikpakTrafficBytes(quota.used)) used / \(pikpakTrafficBytes(quota.total))")
                    .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
                ProgressView(value: quota.usedFraction).tint(pikpakTrafficColor(quota))
                Text(quota.used > quota.total ? "\(pikpakTrafficBytes(quota.used - quota.total)) over the limit" : quota.used == quota.total ? "Limit reached" : "\(pikpakTrafficBytes(quota.remaining)) remaining")
                    .font(.caption2).foregroundStyle(quota.used >= quota.total ? .red : .secondary)
            } else {
                Text(isRefreshing ? "Loading…" : "Unavailable from PikPak").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

func pikpakTrafficColor(_ quota: StorageQuota) -> Color {
    if quota.used >= quota.total { return .red }
    return quota.usedFraction >= 0.9 ? .orange : FinderAppearance.accent
}

func pikpakTrafficBytes(_ bytes: UInt64) -> String {
    guard bytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
}
