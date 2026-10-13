import AppKit
import SwiftUI

/// Measurements cover this synthetic app only. No accounts or cloud helpers.
@MainActor
enum BrowserScrollDiagnostics {
    static var disableCursor = false
    static var disableDropGeometry = false
    static var outlineBuilds = 0
    static var rowConstructions = 0
    static var rowBodies = 0
    static var geometryPasses = 0
    static var geometryZones = 0
    static var maximumZones = 0
    static var cursorResets = 0
    static var applicationLookups = 0
    static var uniqueRows = Set<String>()
    static func constructRow(_ id: String) { rowConstructions += 1; uniqueRows.insert(id) }
    static func resolveGeometry(_ count: Int) {
        geometryPasses += 1; geometryZones += count; maximumZones = max(maximumZones, count)
    }
    static func reset() {
        outlineBuilds = 0; rowConstructions = 0; rowBodies = 0; geometryPasses = 0
        geometryZones = 0; maximumZones = 0; cursorResets = 0; applicationLookups = 0; uniqueRows = []
    }
    static var summary: String {
        "outlines=\(outlineBuilds) rows=\(rowConstructions) unique=\(uniqueRows.count) bodies=\(rowBodies) geometry_passes=\(geometryPasses) geometry_zones=\(geometryZones) maximum_zones=\(maximumZones) cursor_resets=\(cursorResets) app_lookups=\(applicationLookups)"
    }
}

@MainActor
final class BrowserScrollBenchmark: ObservableObject {
    @Published var variant = "Baseline"
    @Published var result = "Command-Shift-B: run 15-second scroll benchmark"
    private var timer: Timer?

    func selectVariant(_ value: String) {
        guard timer == nil else { return }
        BrowserScrollDiagnostics.disableCursor = value == "No cursor" || value == "Neither"
        BrowserScrollDiagnostics.disableDropGeometry = value == "No drop geometry" || value == "Neither"
        BrowserScrollDiagnostics.reset()
        result = "Command-Shift-B: run 15-second scroll benchmark"
        variant = value
    }

    func run() {
        guard timer == nil, let window = NSApp.windows.first(where: { $0.title.contains("Scrolling") }),
              let content = window.contentView else { return }
        // Descend through horizontal containers too; the vertical document is
        // the only one with a large height. This is test-app code, not an event injector.
        func descendants(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(descendants)
        }
        guard let scroll = descendants(content).max(by: {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        }), let document = scroll.documentView else { return }
        result = "Measuring scrolling…"
        let initial = BrowserScrollDiagnostics.summary
        BrowserScrollDiagnostics.reset()
        let started = ProcessInfo.processInfo.systemUptime
        let cpuStart = TaskResourceSampler.sample().first { $0.pid == getpid() }!.cpuNanoseconds
        var previous = started, maximumDelay = 0.0, frames = 0, stalls = 0
        var position: CGFloat = 0, direction: CGFloat = 1
        let next = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let self, let scroll else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delay = now - previous
                previous = now
                maximumDelay = max(maximumDelay, delay)
                if delay > 0.05 { stalls += 1 }
                frames += 1
                let limit = max(0, document.bounds.height - scroll.contentView.bounds.height)
                position = min(max(position + 45 * direction, 0), limit)
                if position == limit { direction = -1 }
                else if position == 0 { direction = 1 }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
                scroll.reflectScrolledClipView(scroll.contentView)
                guard now - started >= 15 else { return }
                self.timer?.invalidate(); self.timer = nil
                let cpuEnd = TaskResourceSampler.sample().first { $0.pid == getpid() }!.cpuNanoseconds
                let cpu = Double(cpuEnd - cpuStart) / ((now - started) * 1_000_000_000) * 100
                self.result = String(format: "Frames: %d · stalls >50 ms: %d · worst: %.0f ms · CPU: %.1f%%", frames, stalls, maximumDelay * 1000, cpu)
                let report = "\(self.variant) · \(self.result)\ninitial: \(initial)\nscroll: \(BrowserScrollDiagnostics.summary)\n"
                let name = Bundle.main.bundleIdentifier ?? "PikPakScrolling"
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-scroll.txt")
                let previousReport = (try? String(contentsOf: path)) ?? ""
                try? (previousReport + report).write(to: path, atomically: true, encoding: .utf8)
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

@main
struct BrowserScrollingUITestApp: App {
    @StateObject private var model: DownloaderModel
    @StateObject private var benchmark = BrowserScrollBenchmark()

    init() {
        let model = DownloaderModel.finderWorkspaceFixture()
        if Bundle.main.object(forInfoDictionaryKey: "ScrollFixtureSource") as? String == "links" {
            model.populateScrollingFixture(count: 5000, links: true)
        } else {
            model.populateExpandedScrollingFixture()
        }
        _model = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        WindowGroup("PikPak · Scrolling Test") {
            VStack(spacing: 0) {
                ContentView().environmentObject(model).environmentObject(model.finderSettings).id(benchmark.variant)
                BenchmarkStatus(benchmark: benchmark)
            }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            FinderCommands(settings: model.finderSettings)
            CommandMenu("Benchmark") {
                Button("Run Scroll Benchmark", action: benchmark.run).keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Baseline") { benchmark.selectVariant("Baseline") }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Disable Cursor Views") { benchmark.selectVariant("No cursor") }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Disable Drop Geometry") { benchmark.selectVariant("No drop geometry") }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Disable Both") { benchmark.selectVariant("Neither") }.keyboardShortcut("4", modifiers: [.command, .option])
                Button("500 Rows") { BrowserScrollDiagnostics.reset(); model.populateScrollingFixture(count: 500) }
                Button("5,000 Rows") { BrowserScrollDiagnostics.reset(); model.populateScrollingFixture(count: 5000) }
                Button("20,000 Rows") { BrowserScrollDiagnostics.reset(); model.populateScrollingFixture(count: 20000) }
                Button("20,200 Expanded Rows") { BrowserScrollDiagnostics.reset(); model.populateExpandedScrollingFixture() }
                Button("50,500 Expanded Rows") { BrowserScrollDiagnostics.reset(); model.populateExpandedScrollingFixture(folderCount: 250) }
            }
        }
    }
}

private struct BenchmarkStatus: View {
    @ObservedObject var benchmark: BrowserScrollBenchmark
    var body: some View { Text(benchmark.result).font(.caption).padding(8) }
}
