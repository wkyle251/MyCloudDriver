import SwiftUI

/// Isolated chart fixture. It reads no accounts, queues or files.
@main struct DownloadSpeedHistoryUITestApp: App {
    private let history: DownloadSpeedSnapshot = {
        let start = Date().addingTimeInterval(-40_000)
        var tracker = DownloadSpeedHistory(), bytes: UInt64 = 0
        tracker.restartCounter(at: start, active: true)
        for second in 1...40_000 {
            let rates: [UInt64] = [5_000_000, 15_000_000, 0, 10_000_000]
            bytes += rates[(second / 1_800) % rates.count]
            tracker.observe(bytes: bytes, active: true, at: start.addingTimeInterval(Double(second)))
        }
        return tracker.snapshot
    }()

    var body: some Scene {
        WindowGroup("Download Speed History QA") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Generated 11-hour download session").font(.title2.weight(.semibold))
                Text("The plotted line should cover the entire timeline, including the earliest half-hour speed changes.")
                    .foregroundStyle(.secondary)
                DownloadSpeedChart(history: history, remainingBytes: 1_000_000_000,
                    estimatedSize: false, lowerBound: false, isRunning: true)
            }
            .padding(20)
            .frame(minWidth: 900, minHeight: 280)
        }
        .defaultSize(width: 1_200, height: 300)
    }
}
