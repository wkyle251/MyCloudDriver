import Foundation
import Darwin

/// Generated counters only. No downloader, account, disk or network is opened.
@main struct DownloadSpeedHistoryTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL \(message)"); exit(1) }
    }

    static func main() {
        DownloadSpeedHistory.testSessionHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        for seconds in [40_000, 172_800] {
            var history = DownloadSpeedHistory(), transferred: UInt64 = 0
            history.restartCounter(at: start, active: true)
            for second in 1...seconds {
                let rate: UInt64 = second == seconds ? 99_000_000
                    : (second / 1_800) % 4 == 0 ? 5_000_000
                    : (second / 1_800) % 4 == 1 ? 15_000_000
                    : (second / 1_800) % 4 == 2 ? 0 : 10_000_000
                transferred += rate
                history.observe(bytes: transferred, active: true, at: start.addingTimeInterval(Double(second)))
                require(history.samples.count <= DownloadSpeedHistory.maximumSamples, "Stored samples exceed the RAM bound")
            }
            let snapshot = history.snapshot
            let firstOffset = snapshot.samples.first!.time.timeIntervalSince(start)
            print("Generated \(seconds)s session: first plotted point at +\(firstOffset)s; \(snapshot.samples.count) chart points")
            require(snapshot.samples.first?.time == start, "The chart must retain its original start after repeated compression")
            require(snapshot.samples.count <= DownloadSpeedHistory.maximumChartSamples, "Chart sample bound changed")
            require(snapshot.samples.last?.time == start.addingTimeInterval(Double(seconds)), "The chart must retain its latest timestamp")
            require(snapshot.samples.last?.bytesPerSecond == 99_000_000, "Compression must preserve the latest measured speed")
            let gaps = zip(snapshot.samples, snapshot.samples.dropFirst()).map { $1.time.timeIntervalSince($0.time) }
            let maximumGap = Double(seconds) / Double(DownloadSpeedHistory.maximumChartSamples - 2) * 2.5
            require((gaps.max() ?? 0) <= maximumGap, "Early history lost coverage while recent samples crowded the chart")
            require(snapshot.transferredBytes == Double(transferred) && snapshot.activeSeconds == Double(seconds), "Compression changed traffic or active time")
            let expectedAverage = Double(transferred) / Double(seconds)
            require(snapshot.averageBytesPerSecond == expectedAverage, "Overall average changed")
            for samples in [history.samples, snapshot.samples] {
                let weightedBytes = samples.reduce(0.0) { $0 + $1.bytesPerSecond * $1.duration }
                let duration = samples.reduce(0.0) { $0 + $1.duration }
                require(abs(weightedBytes - Double(transferred)) < Double(transferred) * 1e-10, "Time-weighted traffic was lost during compression")
                require(duration == Double(seconds), "Compacted sample duration changed")
                require(zip(samples, samples.dropFirst()).allSatisfy { $0.time < $1.time }, "Chart timestamps must remain ordered and unique")
            }
        }
        print("PASS long download charts retain the beginning, full timeline, latest speed and time-weighted totals in bounded RAM")
    }
}
