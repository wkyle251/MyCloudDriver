import SwiftUI

struct ActivityLogPanel: View {
    let log: ActivityLogBuffer
    let busy: Bool
    @Binding var expanded: Bool
    let clear: () -> Void
    var status = AnyView(EmptyView())
    @State private var filter = ActivityLogFilter.all

    private var visibleEntries: [ActivityLogEntry] { log.entries(matching: filter) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: busy ? "bolt.horizontal.fill" : "checkmark.circle.fill")
                            .foregroundStyle(busy ? Color.orange : Color.green)
                        Text("Activity Log").font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse Activity Log" : "Expand Activity Log")
                .accessibilityLabel(expanded ? "Collapse Activity Log" : "Expand Activity Log")
                .fixedSize()
                if log.errorCount > 0 {
                    Button {
                        filter = .error
                        expanded = true
                    } label: {
                        Label("\(log.errorCount.formatted()) \(log.errorCount == 1 ? "error" : "errors")", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Show errors in Activity Log")
                    .accessibilityLabel("Show activity log errors")
                }
                Picker("Log level", selection: $filter) {
                    ForEach(ActivityLogFilter.allCases) { level in Text(level.title).tag(level) }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small)
                .frame(width: 105)
                .accessibilityLabel("Activity log level")
                Divider().frame(height: 14)
                status.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: clear) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).disabled(log.entries.isEmpty)
                    .help("Clear Activity").accessibilityLabel("Clear Activity")
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
            if expanded {
                VStack(spacing: 9) {
                    HStack(spacing: 10) {
                        Text("\(visibleEntries.count.formatted()) \(visibleEntries.count == 1 ? "entry" : "entries")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Open Saved Logs") {
                            NSWorkspace.shared.open(DownloadDiagnosticsStore.shared.directory)
                        }
                        .help("Download diagnostics: up to eight days, within 128 MiB. Filenames, paths and credentials are excluded.")
                        Button("Copy Diagnostics") {
                            let text = DownloadDiagnosticsStore.shared.recentText()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .help("Copy the latest 512 KiB of anonymous download diagnostics.")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                if log.trimmed {
                                    Text("Older activity trimmed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if visibleEntries.isEmpty {
                                    Text(log.entries.isEmpty ? "Ready for your next download." : "No \(filter.title.lowercased()) entries.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(visibleEntries) { entry in
                                    HStack(alignment: .top, spacing: 9) {
                                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                            .monospacedDigit().foregroundStyle(.secondary)
                                            .fixedSize()
                                        Text(entry.level.title.uppercased())
                                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                            .foregroundStyle(color(entry.level))
                                            .frame(width: 55, alignment: .leading)
                                        Text(entry.message)
                                            .foregroundStyle(entry.level == .error ? Color.red : Color.primary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(entry.level.title): \(entry.message)")
                                }
                                Color.clear.frame(height: 1).id("activity-end")
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .onChange(of: log.revision) { _ in proxy.scrollTo("activity-end", anchor: .bottom) }
                        .onChange(of: filter) { _ in proxy.scrollTo("activity-end", anchor: .bottom) }
                    }
                    .frame(height: 150)
                }.padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain).accessibilityLabel("Workspace footer")
        .onChange(of: filter) { _ in expanded = true }
    }

    private func color(_ level: ActivityLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
