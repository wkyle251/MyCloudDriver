import Foundation
import Charts
import SwiftUI

struct DownloadSpeedSample: Identifiable, Equatable {
    let time: Date
    let bytesPerSecond: Double
    let duration: TimeInterval
    var id: Date { time }
}

struct DownloadSpeedSnapshot: Equatable {
    var samples: [DownloadSpeedSample] = []
    var startedAt: Date?
    var averageBytesPerSecond: Double = 0
    var transferredBytes: Double = 0
    var activeSeconds: TimeInterval = 0

    func estimatedSeconds(remainingBytes: UInt64) -> TimeInterval? {
        guard averageBytesPerSecond > 0, averageBytesPerSecond.isFinite else { return nil }
        let seconds = Double(remainingBytes) / averageBytesPerSecond
        return seconds.isFinite ? seconds : nil
    }

    func estimatedCompletionDate(remainingBytes: UInt64, at now: Date) -> Date? {
        guard let seconds = estimatedSeconds(remainingBytes: remainingBytes),
              seconds <= Date.distantFuture.timeIntervalSince(now) else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// Match the chart's linear segments using time alone, regardless of the
    /// pointer's vertical position. Clamp the empty margins to real endpoints.
    func interpolatedSample(at time: Date) -> DownloadSpeedSample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }
        guard let upper = samples.firstIndex(where: { $0.time >= time }), upper > 0 else { return first }
        let before = samples[upper - 1], after = samples[upper]
        if time == after.time { return after }
        let fraction = time.timeIntervalSince(before.time) / after.time.timeIntervalSince(before.time)
        return .init(time: time,
            bytesPerSecond: before.bytesPerSecond + (after.bytesPerSecond - before.bytesPerSecond) * fraction,
            duration: 0)
    }
}

/// RAM only. Old samples are merged into time-weighted buckets, retaining the
/// whole session in bounded memory. Totals are independent of chart compaction.
struct DownloadSpeedHistory {
    static let maximumSamples = 4_096
    static let maximumChartSamples = 360
    private(set) var samples: [DownloadSpeedSample] = []
    private var startedAt: Date?
    private var lastDate: Date?
    private var lastBytes: UInt64 = 0
    private var wasActive = false
    private var transferredBytes: Double = 0
    private var activeSeconds: TimeInterval = 0
    private var pendingBytes: Double = 0
    private var pendingSeconds: TimeInterval = 0

    mutating func restartCounter(bytes: UInt64 = 0, at now: Date, active: Bool) {
        lastBytes = bytes
        lastDate = now
        wasActive = active
        if active, startedAt == nil { startedAt = now }
    }

    /// Counters contain actual network bytes, excluding existing partial files
    /// and files skipped on disk. A new helper's counter can start at zero.
    @discardableResult
    mutating func observe(bytes: UInt64, active: Bool, at now: Date) -> Bool {
        guard let previous = lastDate else {
            restartCounter(bytes: bytes, at: now, active: active)
            return active
        }
        guard now >= previous else { return false }
        let interval = now.timeIntervalSince(previous)
        let delta = Double(bytes >= lastBytes ? bytes - lastBytes : bytes)
        let changedState = wasActive != active
        if wasActive || (active && delta > 0) {
            // The first payload belongs to the latest measured interval, not
            // the preceding queue preparation. Retain those first bytes.
            if startedAt == nil { startedAt = previous }
            else if !wasActive, let last = samples.last, last.time < previous {
                append(time: previous, speed: 0, duration: 0)
            }
            activeSeconds += interval
            transferredBytes += delta
            pendingBytes += delta
            pendingSeconds += interval
        } else if active {
            // Represent the paused gap without adding it to the average.
            if startedAt != nil, interval > 0 { append(time: now, speed: 0, duration: interval) }
            if startedAt == nil { startedAt = now }
        }
        lastDate = now; lastBytes = bytes; wasActive = active
        var changed = false
        if pendingSeconds >= 1 || (changedState && pendingSeconds > 0) {
            append(time: now, speed: pendingBytes / pendingSeconds, duration: pendingSeconds)
            pendingBytes = 0; pendingSeconds = 0
            changed = true
        }
        if changedState, !active, startedAt != nil {
            append(time: now.addingTimeInterval(0.000001), speed: 0, duration: 0)
            changed = true
        }
        return changed || changedState
    }

    private mutating func append(time: Date, speed: Double, duration: TimeInterval) {
        let speed = max(0, speed)
        if samples.isEmpty, let startedAt, startedAt < time {
            // The first rate covers the interval from the session's start.
            // Anchor that edge without counting its bytes or duration twice.
            samples.append(.init(time: startedAt, bytesPerSecond: speed, duration: 0))
        }
        samples.append(.init(time: time, bytesPerSecond: speed, duration: duration))
        if samples.count > Self.maximumSamples {
            samples = Self.coalesced(samples, limit: Self.maximumSamples / 2)
        }
    }

    private static func coalesced(_ input: [DownloadSpeedSample], limit: Int) -> [DownloadSpeedSample] {
        guard input.count > limit else { return input }
        let first = input.first!, last = input.last!
        let bucketCount = limit - 2
        let span = last.time.timeIntervalSince(first.time)
        func bucketIndex(_ index: Int) -> Int {
            let position = span > 0
                ? input[index].time.timeIntervalSince(first.time) / span
                : Double(index - 1) / Double(input.count - 2)
            return min(bucketCount - 1, max(0, Int(position * Double(bucketCount))))
        }

        // Equal-time buckets retain coverage across the entire session. Merging
        // by sample count repeatedly consumes the oldest, already-merged points
        // and moves the beginning of the plotted line forward by hours.
        var result = [first]
        var start = 1
        while start < input.count - 1 {
            let index = bucketIndex(start)
            var end = start + 1
            while end < input.count - 1, bucketIndex(end) == index { end += 1 }
            let bucket = input[start..<end]
            let seconds = bucket.reduce(0) { $0 + $1.duration }
            let speed = seconds > 0 ? bucket.reduce(0) { $0 + $1.bytesPerSecond * $1.duration } / seconds
                : bucket.last!.bytesPerSecond
            result.append(.init(time: bucket.last!.time, bytesPerSecond: speed, duration: seconds))
            start = end
        }
        // Keep the current rate exact; callers also use it as the live speed.
        result.append(last)
        return result
    }

    var snapshot: DownloadSpeedSnapshot {
        .init(samples: Self.coalesced(samples, limit: Self.maximumChartSamples), startedAt: startedAt,
            averageBytesPerSecond: activeSeconds > 0 ? transferredBytes / activeSeconds : 0,
            transferredBytes: transferredBytes, activeSeconds: activeSeconds)
    }
}

struct DownloadSpeedChart: View {
    let history: DownloadSpeedSnapshot
    let remainingBytes: UInt64?
    let estimatedSize: Bool
    let lowerBound: Bool
    let isRunning: Bool
    var waitingMessage: String? = nil
    @AppStorage("downloadSpeedChartExpanded") private var isExpanded = true
    @State private var hoveredTime: Date?

    private var average: String {
        guard history.averageBytesPerSecond > 0 else { return waitingMessage == nil ? "Calculating…" : "Waiting for data…" }
        return String(format: "%.2f MB/s", history.averageBytesPerSecond / 1_000_000)
    }

    private var timeRemaining: String {
        if waitingMessage != nil { return "Waiting for download data…" }
        guard let remainingBytes else { return "Calculating remaining size…" }
        if remainingBytes == 0, !estimatedSize { return "Complete" }
        guard remainingBytes > 0, let seconds = history.estimatedSeconds(remainingBytes: remainingBytes) else {
            return "Calculating time…"
        }
        let total = SafeDisplayNumber.integer(seconds, rounding: .up)
        let time = total < 60 ? "\(total)s" : total < 3_600 ? "\(total / 60)m \(total % 60)s"
            : "\(total / 3_600)h \((total % 3_600) / 60)m"
        let prefix = lowerBound ? "At least ~" : "~"
        return (isRunning ? "" : "When resumed: ") + prefix + time
    }

    private var completionEstimate: String {
        if waitingMessage != nil { return "Waiting for download data…" }
        guard let remainingBytes else { return "Calculating remaining size…" }
        if remainingBytes == 0, !estimatedSize { return "Complete" }
        guard isRunning else { return "Resume to estimate finish" }
        guard remainingBytes > 0,
              let date = history.estimatedCompletionDate(remainingBytes: remainingBytes, at: Date()) else {
            return "Calculating time…"
        }
        return (lowerBound ? "At least ~" : "~") + date.formatted(date: .abbreviated, time: .shortened)
    }

    private var hoveredSample: DownloadSpeedSample? {
        hoveredTime.flatMap { history.interpolatedSample(at: $0) }
    }

    private var speedSummary: some View {
        Text("Overall average: \(average)").foregroundStyle(.secondary)
            .help("Average speed includes stalls after reception starts and excludes preparation and pauses. History stays in RAM and clears when the app restarts.")
    }

    private var completionSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Estimated time left: \(timeRemaining)")
            Text("Estimated completion: \(completionEstimate)")
        }.fontWeight(.medium)
    }

    private var timeDomain: ClosedRange<Date> {
        let start = history.startedAt ?? Date()
        let end = max(history.samples.last?.time ?? start, start.addingTimeInterval(1))
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                    hoveredTime = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Label("Download speed", systemImage: "chart.xyaxis.line")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(isExpanded ? "Hide" : "Show").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse download speed" : "Expand download speed")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help(isExpanded ? "Hide the speed chart and estimates" : "Show the speed chart and estimates")
            if isExpanded { details.padding(.top, 8) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let waitingMessage {
                Label(waitingMessage + " Speed chart paused until data arrives.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    speedSummary
                    Spacer(minLength: 8)
                    completionSummary
                }
                VStack(alignment: .leading, spacing: 8) {
                    speedSummary
                    completionSummary
                }
            }.font(.caption).monospacedDigit()
            if history.samples.isEmpty {
                Text("Speed history will appear when downloads start.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                Chart {
                    ForEach(history.samples) { point in
                        AreaMark(x: .value("Time", point.time), y: .value("MB/s", point.bytesPerSecond / 1_000_000))
                            .foregroundStyle(.blue.opacity(0.12))
                        LineMark(x: .value("Time", point.time), y: .value("MB/s", point.bytesPerSecond / 1_000_000))
                            .foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.linear)
                    }
                    RuleMark(y: .value("Overall average", history.averageBytesPerSecond / 1_000_000))
                        .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    if let point = hoveredSample {
                        RuleMark(x: .value("Selected time", point.time))
                            .foregroundStyle(.blue.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        PointMark(x: .value("Time", point.time), y: .value("MB/s", point.bytesPerSecond / 1_000_000))
                            .foregroundStyle(.blue).symbolSize(35)
                    }
                }
                .chartXScale(domain: timeDomain)
                .chartYScale(domain: 0.0...100.0)
                .chartYAxisLabel("MB/s")
                .chartYAxis { AxisMarks(position: .leading, values: [0, 50, 100]) }
                .chartPlotStyle { plot in plot.clipped() }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 105)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        let plot = geometry[proxy.plotAreaFrame]
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        hoveredTime = plot.contains(location)
                                            ? proxy.value(atX: location.x - plot.minX, as: Date.self) : nil
                                    case .ended:
                                        hoveredTime = nil
                                    }
                                }
                            if let point = hoveredSample, let x = proxy.position(forX: point.time) {
                                let width = min(200, plot.width)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.time.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption2)
                                    Text(String(format: "%.2f MB/s", point.bytesPerSecond / 1_000_000))
                                        .font(.caption.weight(.semibold))
                                }
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(width: width, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .position(x: min(max(plot.minX + x, plot.minX + width / 2), plot.maxX - width / 2),
                                    y: plot.minY + 24)
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .accessibilityLabel("Download speed over time")
                .accessibilityValue("Overall average \(average). Estimated time left \(timeRemaining). Estimated completion \(completionEstimate).")
            }
            Text((estimatedSize ? "Time uses the current remaining-size estimate and the overall average speed."
                : "Time = remaining bytes ÷ overall average speed.") + " Hover anywhere in the chart to inspect speed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

#if FINDER_WORKSPACE_TESTS
extension DownloadSpeedHistory {
    static func testSessionHistory() {
        let start = Date(timeIntervalSince1970: 1_000)
        var history = Self()
        history.restartCounter(at: start, active: true)
        history.observe(bytes: 200, active: true, at: start.addingTimeInterval(2))
        precondition(history.snapshot.averageBytesPerSecond == 100)
        history.observe(bytes: 200, active: true, at: start.addingTimeInterval(4))
        precondition(history.snapshot.averageBytesPerSecond == 50, "Stalls belong to the overall average")
        history.observe(bytes: 200, active: false, at: start.addingTimeInterval(4))
        history.observe(bytes: 200, active: false, at: start.addingTimeInterval(104))
        history.observe(bytes: 200, active: true, at: start.addingTimeInterval(104))
        history.observe(bytes: 400, active: true, at: start.addingTimeInterval(106))
        precondition(history.snapshot.activeSeconds == 6, "Explicit pauses are excluded")
        precondition(abs(history.snapshot.estimatedSeconds(remainingBytes: 600)! - 9) < 0.000001)
        history.restartCounter(at: start.addingTimeInterval(106), active: true)
        history.observe(bytes: 100, active: true, at: start.addingTimeInterval(108))
        precondition(history.snapshot.transferredBytes == 500 && history.snapshot.averageBytesPerSecond == 62.5,
            "Helper restarts retain history without counting an old counter twice")
        // A resumed prefix is a baseline, never new network traffic.
        history.restartCounter(bytes: 10_000, at: start.addingTimeInterval(108), active: true)
        history.observe(bytes: 10_100, active: true, at: start.addingTimeInterval(110))
        precondition(history.snapshot.transferredBytes == 600)
        var weighted = Self()
        weighted.restartCounter(at: start, active: true)
        weighted.observe(bytes: 1_000_000, active: true, at: start.addingTimeInterval(1))
        weighted.observe(bytes: 46_000_000, active: true, at: start.addingTimeInterval(10))
        precondition(weighted.snapshot.averageBytesPerSecond == 4_600_000, "Average is bytes/time, not an unweighted mean of rates")
        var long = Self()
        long.restartCounter(at: start, active: true)
        for second in 1...20_000 {
            long.observe(bytes: UInt64(second * 100), active: true, at: start.addingTimeInterval(Double(second)))
            precondition(long.samples.count <= Self.maximumSamples)
        }
        precondition(long.snapshot.samples.count <= Self.maximumChartSamples)
        precondition(long.snapshot.startedAt == start && long.snapshot.samples.last?.time == start.addingTimeInterval(20_000))
        precondition(long.snapshot.averageBytesPerSecond == 100 && long.snapshot.transferredBytes == 2_000_000)
        let fresh = Self()
        precondition(fresh.snapshot.samples.isEmpty && fresh.snapshot.estimatedSeconds(remainingBytes: 100) == nil,
            "A new app model starts with no speed history")
        let midnight = Date(timeIntervalSince1970: 86_400)
        precondition(weighted.snapshot.estimatedCompletionDate(remainingBytes: 55_200_000, at: midnight.addingTimeInterval(-3))
            == midnight.addingTimeInterval(9), "The completion date crosses midnight using remaining bytes / average speed")
        precondition(fresh.snapshot.estimatedCompletionDate(remainingBytes: 100, at: start) == nil)
        precondition(history.snapshot.estimatedCompletionDate(remainingBytes: .max, at: start) == nil,
            "Unrepresentable completion dates are not sent to the date formatter")
        let sparse = DownloadSpeedSnapshot(samples: [
            .init(time: start, bytesPerSecond: 1_000_000, duration: 1),
            .init(time: start.addingTimeInterval(10), bytesPerSecond: 5_000_000, duration: 10),
            .init(time: start.addingTimeInterval(20), bytesPerSecond: 0, duration: 10)
        ])
        let middle = sparse.interpolatedSample(at: start.addingTimeInterval(5))!
        precondition(middle.time == start.addingTimeInterval(5) && middle.bytesPerSecond == 3_000_000,
            "A time between recorded samples reads the plotted line's speed")
        precondition(sparse.interpolatedSample(at: start.addingTimeInterval(15))!.bytesPerSecond == 2_500_000)
        precondition(sparse.interpolatedSample(at: start.addingTimeInterval(10)) == sparse.samples[1])
        precondition(sparse.interpolatedSample(at: start.addingTimeInterval(-10)) == sparse.samples.first)
        precondition(sparse.interpolatedSample(at: start.addingTimeInterval(30)) == sparse.samples.last)
        precondition(fresh.snapshot.interpolatedSample(at: start) == nil)
        precondition(DownloadSpeedSnapshot(samples: [sparse.samples[0]]).interpolatedSample(at: midnight) == sparse.samples[0])
        print("PASS download graph: bytes/time average, stalls, pause exclusion, remaining/average ETA and finish date, interpolated time selection, resume baselines, helper counter resets, full-session bounded RAM and fresh-session reset")
    }
}
#endif
