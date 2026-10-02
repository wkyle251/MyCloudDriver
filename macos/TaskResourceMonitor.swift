import AppKit
import Darwin
import SwiftUI

struct TaskProcessSample: Sendable {
    let pid: Int32
    let name: String
    let started: UInt64
    let cpuNanoseconds: UInt64
    let residentBytes: UInt64
    let threads: Int
    var parentPID: Int32 = 0
}

struct TaskResourceRow: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let cpuPercent: Double?
    let residentBytes: UInt64
    let threads: Int
    var parentPID: Int32 = 0
    var id: Int32 { pid }
}

struct TaskResourceActivity: Sendable, Equatable {
    let name: String
    var detail: String = ""
    var symbol: String = "gearshape.2"
    var processing: TaskResourceProcessing? = nil
}

struct TaskResourceGroup: Identifiable, Sendable {
    let id: Int32
    let activity: TaskResourceActivity
    let processIDs: [Int32]
    let cpuPercent: Double?
    let residentBytes: UInt64

    var processDescription: String {
        "\(processIDs.count == 1 ? "PID" : "PIDs") \(processIDs.map(String.init).joined(separator: ", "))"
    }
}

/// A task can launch more helpers (for example archive password workers).
/// Attribute each process once, to its closest named ancestor. Unnamed helpers
/// remain visible instead of being silently included in the interface's usage.
enum TaskResourceAttribution {
    static func group(_ rows: [TaskResourceRow], activities: [Int32: TaskResourceActivity],
                      rootPID: Int32 = getpid()) -> [TaskResourceGroup] {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
        func owner(of row: TaskResourceRow) -> Int32 {
            var current = row
            var visited = Set<Int32>()
            while visited.insert(current.pid).inserted {
                if current.pid == rootPID || activities[current.pid] != nil { return current.pid }
                guard current.parentPID != rootPID, current.parentPID > 0 else { return current.pid }
                if activities[current.parentPID] != nil { return current.parentPID }
                guard let parent = byPID[current.parentPID] else { return current.pid }
                current = parent
            }
            return row.pid
        }
        return Dictionary(grouping: rows, by: owner).map { pid, members in
            let fallback = pid == rootPID
                ? TaskResourceActivity(name: "MyCloudDriver", detail: "Interface & shared app work", symbol: "macwindow")
                : TaskResourceActivity(name: "Background helper", detail: byPID[pid]?.name ?? "")
            return TaskResourceGroup(id: pid, activity: activities[pid] ?? fallback,
                processIDs: members.map(\.pid).sorted(),
                cpuPercent: members.allSatisfy { $0.cpuPercent != nil }
                    ? members.reduce(0) { $0 + ($1.cpuPercent ?? 0) } : nil,
                residentBytes: members.reduce(0) { $0 + $1.residentBytes })
        }.sorted {
            if $0.cpuPercent != $1.cpuPercent { return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
            if $0.residentBytes != $1.residentBytes { return $0.residentBytes > $1.residentBytes }
            return $0.id < $1.id
        }
    }
}

/// Delta-based CPU samples, not lifetime averages. A new/reused PID needs two
/// readings. Failed or exited processes disappear instead of keeping stale data.
struct TaskResourceAccumulator {
    private var previous: [Int32: TaskProcessSample] = [:]
    private var previousTime: TimeInterval?

    mutating func update(_ samples: [TaskProcessSample], at time: TimeInterval) -> [TaskResourceRow] {
        let elapsed = previousTime.map { time - $0 }
        let rows = samples.map { sample -> TaskResourceRow in
            var cpu: Double?
            if let old = previous[sample.pid], old.started == sample.started,
               let elapsed, elapsed > 0, elapsed <= 10,
               sample.cpuNanoseconds >= old.cpuNanoseconds {
                cpu = Double(sample.cpuNanoseconds - old.cpuNanoseconds) / (elapsed * 1_000_000_000) * 100
            }
            return TaskResourceRow(pid: sample.pid, name: sample.name, cpuPercent: cpu,
                                   residentBytes: sample.residentBytes, threads: sample.threads,
                                   parentPID: sample.parentPID)
        }
        previous = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
        previousTime = time
        return rows
    }
}

/// Read only this app and descendants, never other apps or command-line args.
/// libproc returns child *counts* here (not bytes). Samples run off the UI thread.
enum TaskResourceSampler {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // PROC_PIDTASKINFO reports Mach ticks, which differ from nanoseconds on
    // Apple silicon. Match Apple's conversion in tests/recount/recount_perf_tests.c.
    static func nanoseconds(fromMachTicks ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        guard denominator > 0, product.high < UInt64(denominator) else { return .max }
        return UInt64(denominator).dividingFullWidth(product).quotient
    }

    static func sample(rootPID: Int32 = getpid()) -> [TaskProcessSample] {
        var queue = [rootPID]
        var visited = Set<Int32>()
        var samples: [TaskProcessSample] = []
        var index = 0
        while index < queue.count, index < 4096 {
            let pid = queue[index]
            index += 1
            guard visited.insert(pid).inserted else { continue }
            var info = proc_taskinfo()
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size,
               proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize {
                var name = [CChar](repeating: 0, count: 256)
                _ = proc_name(pid, &name, UInt32(name.count))
                samples.append(TaskProcessSample(pid: pid,
                    name: pid == rootPID ? "MyCloudDriver" : String(cString: name),
                    started: bsd.pbi_start_tvsec &* 1_000_000 &+ bsd.pbi_start_tvusec,
                    cpuNanoseconds: nanoseconds(fromMachTicks: info.pti_total_user &+ info.pti_total_system,
                                                numerator: timebase.numer, denominator: timebase.denom),
                    residentBytes: info.pti_resident_size, threads: Int(info.pti_threadnum), parentPID: Int32(bsd.pbi_ppid)))
            }
            let count = max(Int(proc_listchildpids(pid, nil, 0)), 0)
            var children = [Int32](repeating: 0, count: min(count + 32, 4096))
            let returned = children.withUnsafeMutableBytes {
                proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
            }
            if returned > 0 {
                queue.append(contentsOf: children.prefix(min(Int(returned), children.count)).filter { $0 > 0 })
            }
        }
        return samples
    }
}

@MainActor
final class TaskResourceMonitor: ObservableObject {
    @Published private(set) var rows: [TaskResourceRow] = []
    @Published private(set) var tasks: [TaskResourceGroup] = []
    @Published private(set) var sampledAt: Date?
    @Published private(set) var gpus: [TaskGPUUsage] = []
    private var generation = UUID()

    func watch(activities: @MainActor () -> [Int32: TaskResourceActivity] = { [:] }) async {
        let ticket = UUID()
        generation = ticket
        var accumulator = TaskResourceAccumulator()
        rows = []
        tasks = []
        sampledAt = nil
        gpus = []
        defer { if generation == ticket { rows = []; tasks = []; gpus = []; sampledAt = nil } }
        while !Task.isCancelled {
            let descriptions = activities()
            let snapshot = await Task.detached(priority: .utility) { (TaskResourceSampler.sample(), TaskGPUSampler.sample()) }.value
            guard !Task.isCancelled, generation == ticket else { return }
            rows = accumulator.update(snapshot.0, at: ProcessInfo.processInfo.systemUptime)
            tasks = TaskResourceAttribution.group(rows, activities: descriptions)
            gpus = snapshot.1
            sampledAt = Date()
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
}

struct TaskResourceMonitorView: View {
    @ObservedObject var monitor: TaskResourceMonitor
    private var activitySummary: String {
        guard monitor.sampledAt != nil else { return "Measuring task resources…" }
        guard !monitor.rows.isEmpty else { return "Resource samples are unavailable." }
        return monitor.tasks.contains { $0.id != getpid() }
            ? "Active tasks · highest CPU first" : "App usage · no task helpers are running"
    }
    private var cpu: String {
        if monitor.sampledAt != nil && monitor.rows.isEmpty { return "Unavailable" }
        guard !monitor.rows.isEmpty, monitor.rows.allSatisfy({ $0.cpuPercent != nil }) else { return "Sampling…" }
        return String(format: "%.1f%%", monitor.rows.reduce(0) { $0 + ($1.cpuPercent ?? 0) })
    }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App & task resources").font(.title2.weight(.semibold))
            HStack(spacing: 24) {
                metric("CPU", value: cpu)
                metric("Resident memory", value: monitor.rows.isEmpty ? "—" : bytes(monitor.rows.reduce(0) { $0 + $1.residentBytes }))
                metric("Background tasks", value: monitor.rows.isEmpty ? "—" : monitor.tasks.filter { $0.id != getpid() }.count.formatted())
            }
            gpuUsage
            Text(activitySummary)
                .font(.caption).foregroundStyle(.secondary)
            Table(monitor.tasks) {
                TableColumn("Task") { row in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: row.activity.symbol)
                            .foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.activity.name).fontWeight(.medium).lineLimit(1)
                            if !row.activity.detail.isEmpty {
                                Text(row.activity.detail).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            if let processing = row.activity.processing {
                                HStack(spacing: 6) {
                                    Text(processing.title).foregroundStyle(processing.backend == .coreml ? FinderAppearance.accent : .secondary)
                                    if !processing.detail.isEmpty { Text(processing.detail).foregroundStyle(.secondary) }
                                }
                                .font(.caption2).lineLimit(1).help(processing.help)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .help([row.activity.name, row.activity.detail, row.processDescription].joined(separator: "\n"))
                }
                TableColumn("CPU") { row in
                    Text(row.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—").monospacedDigit()
                }.width(70)
                TableColumn("Memory") { row in Text(bytes(row.residentBytes)).monospacedDigit() }.width(90)
            }
            Text("Updates every 2 seconds. CPU and memory include task helpers; 100% CPU is one core. Memory may include shared pages. CoreML jobs show the scan’s current model activity. Drive servers’ resource usage is not included.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let date = monitor.sampledAt {
                Text("Updated \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var gpuUsage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("GPU · This Mac", systemImage: "cpu").font(.callout.weight(.medium))
                Spacer()
                if monitor.gpus.count == 1, let gpu = monitor.gpus.first {
                    Text(gpu.utilization.map { String(format: "%.0f%%", $0) } ?? "Unavailable")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
            if monitor.gpus.isEmpty {
                Text(monitor.sampledAt == nil ? "Measuring GPU usage…" : "GPU usage is unavailable on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.gpus) { gpu in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(gpu.name)
                        Spacer()
                        if monitor.gpus.count > 1 {
                            Text(gpu.utilization.map { String(format: "%.0f%%", $0) } ?? "Unavailable").monospacedDigit()
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let utilization = gpu.utilization {
                        ProgressView(value: utilization, total: 100).progressViewStyle(.linear)
                            .accessibilityLabel("\(gpu.name) GPU usage across this Mac")
                    }
                }
            }
            Text("Includes all apps on this Mac. CoreML may also use the Neural Engine.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).background(FinderAppearance.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}
