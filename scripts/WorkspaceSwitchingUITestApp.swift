import AppKit
import SwiftUI

/// Actual ContentView with 50,000 synthetic files in each workspace and 102
/// expanded links. No engine, user session, network calls or cloud mutations.
@MainActor
final class WorkspaceSwitchBenchmark: ObservableObject {
    @Published var status = "Measuring Browser / Links switching…"
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var waitingFor: Int?
    private var completion: CheckedContinuation<Void, Never>?
    private var stalls = 0
    private var worst = 0.0
    private var previous = 0.0
    private var ran = false

    func run() async {
        guard !ran else { return }
        ran = true
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        observer = NotificationCenter.default.addObserver(forName: .init("PikPakWorkspacePresented"), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? Int == self.waitingFor else { return }
                self.finishWaiting()
            }
        }
        previous = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let delta = now - self.previous
                self.previous = now
                if delta > 0.05 { self.stalls += 1 }
                self.worst = max(self.worst, delta)
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
        var report = "50,000 account files / 50,000 shared files / 102 expanded links\n"
        for section in [3, 0, 3, 0, 3, 0] {
            let began = ProcessInfo.processInfo.systemUptime
            var response = 0.0
            let timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                self?.finishWaiting()
            }
            await withCheckedContinuation { continuation in
                waitingFor = section
                completion = continuation
                NotificationCenter.default.post(name: .init("PikPakSwitchBenchmark"), object: section)
                response = ProcessInfo.processInfo.systemUptime - began
            }
            let ready = ProcessInfo.processInfo.systemUptime - began
            timeout.cancel()
            report += String(format: "section=%d click_handler_ms=%.2f destination_presented_ms=%.2f\n", section, response * 1000, ready * 1000)
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        report += String(format: "stalls_over_50ms=%d worst_gap_ms=%.2f\n", stalls, worst * 1000)
        cancel()
        let name = Bundle.main.bundleIdentifier ?? "PikPakWorkspaceSwitch"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-switch.txt")
        try? report.write(to: path, atomically: true, encoding: .utf8)
        status = "Tab-switch benchmark complete · synthetic data only"
    }

    private func finishWaiting() {
        let pending = completion
        completion = nil
        waitingFor = nil
        pending?.resume()
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        finishWaiting()
    }
}

@main
struct WorkspaceSwitchingUITestApp: App {
    @StateObject private var model = DownloaderModel.workspaceSwitchFixture()
    @StateObject private var benchmark = WorkspaceSwitchBenchmark()

    var body: some Scene {
        WindowGroup("PikPak · Tab Switching Test") {
            VStack(spacing: 0) {
                ContentView().environmentObject(model).environmentObject(model.finderSettings)
                Text(benchmark.status).font(.caption).padding(6)
            }
            .task { await benchmark.run() }
        }
        .defaultSize(width: 1240, height: 820)
        .commands { FinderCommands(settings: model.finderSettings) }
    }
}
