import Foundation

@main struct DownloadRetryTests {
    static func testRollingSpeed() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        func date(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        func check(_ actual: Double, _ expected: Double) {
            precondition(abs(actual - expected) < 0.000_001, "Expected \(expected) B/s, got \(actual)")
        }
        var burst = DownloadFileRate()
        let counters: [UInt64] = [0, 500, 500, 500, 1500, 1500, 2000, 2000, 2000, 2000, 2000, 2000]
        let rates: [Double] = [0, 500, 250, 500.0 / 3, 375, 300, 300, 300, 300, 100, 100, 0]
        for (second, bytes) in counters.enumerated() {
            check(burst.sample(networkBytes: bytes, at: date(Double(second)), transferring: true), rates[second])
        }
        // Irregular update times must still cover exactly five seconds. A
        // large existing counter must not lose precision for small new deltas.
        var irregular = DownloadFileRate()
        let baseline = UInt64.max - 10_000
        for second in [0.0, 0.2, 0.4, 1.0, 2.1, 3.4, 5.9, 6.9] {
            let speed = irregular.sample(networkBytes: baseline + UInt64((second * 1000).rounded()),
                at: date(second), transferring: true)
            check(speed, second < RollingRate.minimumSpacing ? 0 : 1000)
        }
        check(irregular.sample(networkBytes: 50, at: date(7), transferring: true), 0)
        check(irregular.sample(networkBytes: 1050, at: date(8), transferring: true), 1000)
        check(irregular.sample(networkBytes: 1050, at: date(9), transferring: false), 0)
        check(irregular.sample(networkBytes: 1050, at: date(10), transferring: true), 0)
        check(irregular.sample(networkBytes: 2050, at: date(11), transferring: true), 1000)
        check(irregular.sample(networkBytes: 2050, at: date(11), transferring: true), 1000)
        check(irregular.sample(networkBytes: 2050, at: date(10.5), transferring: true), 0)
        check(irregular.sample(networkBytes: 3050, at: date(11.5), transferring: true), 1000)
        print("PASS five-second speeds: startup, bursts, sliding cutoff, idle decay, irregular samples, large counters, pause/resume and resets")
    }
    @MainActor static func main() throws {
        testRollingSpeed()
        try DownloaderModel.testLiveDownloadQueue()
        try DownloaderModel.testDownloadRetries()
        try DownloaderModel.testPermanentDownloadFailures()
        try DownloaderModel.testQueuedDownloadSizeEstimate()
        try DownloaderModel.testDownloadPausedPlanRecovery()
        try DownloaderModel.testDownloadRetryRowsFollowCurrentAttempt()
        try DownloaderModel.testDownloadFinishedReport()
    }
}
