import Charts
import Foundation
import SwiftUI

/// Acquisition bytes have their own rate: hashing a RAM buffer and completing
/// a file must not inflate the disk/network transfer speed. Pause and restored
/// counters establish a baseline, rather than appearing as a burst of traffic.
struct SimilarityReadHistory {
    private var history = DownloadSpeedHistory()
    private var needsBaseline = true
    private(set) var bytesPerSecond: Double = 0

    @discardableResult mutating func observe(_ progress: SimilarityScanProgress, running: Bool,
                                             restoring: Bool = false, at date: Date) -> Bool {
        let active = running && progress.stage == .analysing && !restoring
        let bytes = progress.originalBytesRead ?? 0
        if needsBaseline || restoring {
            history.restartCounter(bytes: bytes, at: date, active: active)
            needsBaseline = restoring
        }
        let changed = history.observe(bytes: bytes, active: active, at: date)
        let rate = active ? history.snapshot.samples.last?.bytesPerSecond ?? 0 : 0
        let changedRate = bytesPerSecond != rate
        bytesPerSecond = rate
        return changed || changedRate
    }
}

struct SimilarityProcessingWork {
    enum Unit: Equatable { case files, pairs
        var label: String { self == .files ? "files" : "pairs" }
        var rateLabel: String { "\(label)/s" }
    }
    let unit: Unit
    let completed: UInt64
    let total: UInt64?
    let isProcessing: Bool
    init(_ progress: SimilarityScanProgress) {
        unit = [.comparison, .grouping, .finishing].contains(progress.stage) ? .pairs : .files
        isProcessing = progress.stage == .analysing || progress.stage == .comparison
        if unit == .pairs {
            completed = progress.pairsCompared
            total = progress.stage == .comparison ? progress.total : nil
        } else {
            completed = SimilarityScanProgress.cumulative(progress.analysed, progress.skipped)
            total = progress.discoveryComplete ? max(progress.foundFiles, progress.total ?? 0) : nil
        }
    }
    var remaining: UInt64? { total.map { $0 > completed ? $0 - completed : 0 } }
    var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(completed) / Double($0)) : nil } }
    var summary: String {
        if let total { return "\(completed.formatted()) of \(total.formatted()) \(unit.label) processed" }
        return "\(completed.formatted()) \(unit.label) processed · total not known yet"
    }
}

/// The download counter's time-weighted, bounded history also works for work
/// units. Keep file and pair histories separate so a stage change never mixes
/// their rates. Recovered counts are baselines, not newly completed work.
struct SimilarityProcessingHistory {
    private var files = DownloadSpeedHistory()
    private var pairs = DownloadSpeedHistory()
    private var phase: SimilarityProcessingWork.Unit?
    private var needsBaseline = true

    mutating func restart(_ progress: SimilarityScanProgress, at date: Date) {
        files.restartCounter(bytes: SimilarityScanProgress.cumulative(progress.analysed, progress.skipped), at: date, active: false)
        pairs.restartCounter(bytes: progress.pairsCompared, at: date, active: false)
        phase = nil; needsBaseline = true
    }

    @discardableResult mutating func observe(_ progress: SimilarityScanProgress, running: Bool, restoring: Bool = false, at date: Date) -> Bool {
        let work = SimilarityProcessingWork(progress)
        let fileCount = SimilarityScanProgress.cumulative(progress.analysed, progress.skipped)
        let active = running && work.isProcessing && !restoring
        if restoring {
            files.restartCounter(bytes: fileCount, at: date, active: false)
            pairs.restartCounter(bytes: progress.pairsCompared, at: date, active: false)
            needsBaseline = true
        }
        let changedPhase = phase != work.unit
        if changedPhase || (needsBaseline && !restoring) {
            if work.unit == .files { files.restartCounter(bytes: fileCount, at: date, active: active) }
            else { pairs.restartCounter(bytes: progress.pairsCompared, at: date, active: active) }
            needsBaseline = restoring
        }
        phase = work.unit
        let changedFiles = files.observe(bytes: fileCount, active: active && work.unit == .files, at: date)
        let changedPairs = pairs.observe(bytes: progress.pairsCompared, active: active && work.unit == .pairs, at: date)
        return changedPhase || changedFiles || changedPairs
    }

    func snapshot(for progress: SimilarityScanProgress) -> DownloadSpeedSnapshot {
        SimilarityProcessingWork(progress).unit == .files ? files.snapshot : pairs.snapshot
    }
    static func rateLabel(_ value: Double, unit: SimilarityProcessingWork.Unit) -> String {
        let number = value.isFinite ? max(0, value) : 0
        return number.formatted(.number.precision(.fractionLength(0...2))) + " " + unit.rateLabel
    }
}

struct SimilarityProcessingView: View {
    let progress: SimilarityScanProgress
    let history: DownloadSpeedSnapshot
    let running: Bool
    let restoring: Bool
    @AppStorage("similarityProcessingSpeedExpanded") private var expanded = true
    @State private var hoveredTime: Date?
    private var work: SimilarityProcessingWork { .init(progress) }
    private var currentRate: Double { running && !restoring && work.isProcessing ? history.samples.last?.bytesPerSecond ?? 0 : 0 }
    private var average: String { SimilarityProcessingHistory.rateLabel(history.averageBytesPerSecond, unit: work.unit) }
    private var timeRemaining: String {
        guard running else { return "Paused" }
        guard work.isProcessing else { return progress.stage.title }
        guard !restoring else { return "Restoring saved progress…" }
        guard let remaining = work.remaining else { return "Counting files…" }
        if remaining == 0 { return work.unit == .files ? "File analysis complete" : "Comparisons complete" }
        guard let seconds = history.estimatedSeconds(remainingBytes: remaining) else { return "Measuring processing speed…" }
        let count = SafeDisplayNumber.integer(seconds, rounding: .up)
        let duration = count < 60 ? "\(count)s" : count < 3_600 ? "\(count / 60)m \(count % 60)s" : "\(count / 3_600)h \((count % 3_600) / 60)m"
        return "About \(duration) left in this stage"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Processing progress", systemImage: "cpu").font(.callout.weight(.semibold))
                    Spacer()
                    if let fraction = work.fraction { Text("\(Int(fraction * 100))%").font(.callout.monospacedDigit().weight(.semibold)) }
                    else { Text(running ? "In progress…" : "Paused").font(.caption).foregroundStyle(.secondary) }
                }
                if let fraction = work.fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
                else if running { ProgressView().progressViewStyle(.linear) }
                else { ProgressView(value: 0).progressViewStyle(.linear) }
                Text(work.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(work.unit == .files ? "\(progress.analysed.formatted()) analysed · \(progress.unsupportedFiles.formatted()) unsupported · \(progress.failedFiles.formatted()) failed"
                    : "Comparing compatible analysed files and saving their scores")
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine).accessibilityLabel("Processing progress")
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Button { withAnimation { expanded.toggle(); hoveredTime = nil } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                        Label("Processing speed", systemImage: "chart.xyaxis.line").font(.callout.weight(.semibold))
                        Spacer()
                        Text(SimilarityProcessingHistory.rateLabel(currentRate, unit: work.unit)).font(.callout.monospacedDigit().weight(.semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse processing speed" : "Expand processing speed")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text("Stage average: \(average)"); Spacer(); Text(timeRemaining) }
                        VStack(alignment: .leading, spacing: 5) { Text("Stage average: \(average)"); Text(timeRemaining) }
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if history.samples.isEmpty {
                        Text(work.unit == .files ? "Speed history appears as files finish processing." : "Speed history appears as pairs are compared.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
                    } else { chart }
                    Text(work.unit == .files ? "Files processed per second, including reused, unsupported and failed files. Time includes waits and excludes pauses; comparison follows analysis."
                        : "Compared pairs per second. Time includes waits and excludes pauses; preparing results follows comparison.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(13).background(FinderAppearance.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .onChange(of: work.unit) { _ in hoveredTime = nil }
    }
    private var chart: some View {
        let start = history.startedAt ?? Date()
        let end = max(history.samples.last?.time ?? start, start.addingTimeInterval(1))
        let hovered = hoveredTime.flatMap { history.interpolatedSample(at: $0) }
        return Chart {
            ForEach(history.samples) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value(work.unit.rateLabel, sample.bytesPerSecond)).foregroundStyle(.blue.opacity(0.12))
                LineMark(x: .value("Time", sample.time), y: .value(work.unit.rateLabel, sample.bytesPerSecond)).foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            RuleMark(y: .value("Stage average", history.averageBytesPerSecond)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if let hovered {
                RuleMark(x: .value("Selected time", hovered.time)).foregroundStyle(.blue.opacity(0.5))
                    .annotation(position: .top, alignment: .leading) {
                        Text(SimilarityProcessingHistory.rateLabel(hovered.bytesPerSecond, unit: work.unit))
                            .font(.caption.monospacedDigit()).padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
        }.chartXScale(domain: start...end).chartYScale(domain: .automatic(includesZero: true))
            .chartYAxisLabel(work.unit.rateLabel).chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.frame(height: 105)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geometry[proxy.plotAreaFrame]
                            hoveredTime = plot.contains(location) ? proxy.value(atX: location.x - plot.minX, as: Date.self) : nil
                        case .ended: hoveredTime = nil
                        }
                    }
                }
            }.accessibilityLabel("Processing speed over time").accessibilityValue("Stage average \(average). \(timeRemaining)")
    }
}
