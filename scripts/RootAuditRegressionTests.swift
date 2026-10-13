import AppKit
import Foundation

private final class RootAuditValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
    var snapshot: Value { lock.lock(); defer { lock.unlock() }; return value }
}

/// Source helpers and generated loopback-free Finder promises only. No live accounts or user files.
@main struct RootAuditRegressionTests {
    @MainActor static func main() async throws {
        sharedLinkIdentity()
        textBoundaries()
        displayBounds()
        processOutputBounds()
        try await processLines()
        try await queuedPromiseCancellation()
        terminalTransferStates()
        discoveredDownloadTotals()
        rollingTransferRate()
        downloadReportText()
        try DownloaderModel.testRootAuditModelSafety()
    }

    static func rollingTransferRate() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        func at(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        func near(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 1e-9 } ?? false }

        var steady = RollingRate()
        precondition(steady.sample(bytes: 0, at: at(0)) == 0, "The first sample only sets the baseline")
        var bytes: UInt64 = 0
        for second in 1...12 {
            bytes += 100
            precondition(near(steady.sample(bytes: bytes, at: at(Double(second))), 100),
                "A constant 100 B/s reads 100 B/s while the window fills and once it slides")
        }

        var burst = RollingRate()
        burst.restart(bytes: 0, at: at(0))
        let afterBurst = (1...7).map { burst.sample(bytes: 1_000, at: at(Double($0))) }
        precondition(near(afterBurst[0], 1_000) && near(afterBurst[1], 500) && near(afterBurst[4], 200),
            "A one-second burst is averaged over the time elapsed so far, then over the whole window")
        precondition(afterBurst[5] == 0 && afterBurst[6] == 0, "A stall fades to zero once the burst has left the five-second window")

        var step = RollingRate()
        step.restart(bytes: 0, at: at(0))
        for second in 1...5 { _ = step.sample(bytes: UInt64(second) * 100, at: at(Double(second))) }
        precondition(near(step.sample(bytes: 1_100, at: at(6)), 200),
            "Speeding up to 600 B/s for one second moves a 100 B/s five-second average only to 200 B/s")

        var straddle = RollingRate()
        straddle.restart(bytes: 0, at: at(0))
        _ = straddle.sample(bytes: 400, at: at(4))
        precondition(near(straddle.sample(bytes: 1_000, at: at(8)), 140),
            "The byte count at the window start is interpolated between the samples that surround it")

        var gated = RollingRate()
        gated.restart(bytes: 0, at: at(0))
        precondition(near(gated.sample(bytes: 100, at: at(1)), 100))
        precondition(gated.sample(bytes: 10_000, at: at(1.5)) == nil && gated.bytesPerSecond == 100,
            "A request closer than the refresh spacing takes no new measurement and changes nothing")
        precondition(near(gated.sample(bytes: 200, at: at(2)), 100), "...and leaves no trace in later averages")

        var reset = RollingRate()
        reset.restart(bytes: 0, at: at(0))
        precondition(near(reset.sample(bytes: 500, at: at(1)), 500))
        precondition(reset.sample(bytes: 50, at: at(2)) == 0, "A counter that goes backwards starts a fresh measurement")
        precondition(near(reset.sample(bytes: 150, at: at(3)), 100))
        precondition(reset.sample(bytes: 400, at: at(1)) == 0, "A clock that goes backwards starts a fresh measurement")

        var file = DownloadFileRate()
        precondition(file.sample(networkBytes: 0, at: at(0), transferring: true) == 0)
        precondition(near(file.sample(networkBytes: 500, at: at(1), transferring: true), 500))
        precondition(file.sample(networkBytes: 500, at: at(2), transferring: false) == 0 && file.bytesPerSecond == 0,
            "A file that is not transferring reports no speed and rebases its counter")
        precondition(near(file.sample(networkBytes: 800, at: at(3), transferring: true), 300))
        print("PASS rolling transfer rate: five-second average, burst and stall fade, interpolated window start, refresh spacing, counter/clock resets and per-file rebasing")
    }

    static func downloadReportText() {
        var batch = DownloadBatch(startedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        batch.completedFiles = 157; batch.skippedFiles = 3
        batch.savedBytes = 18_200_000_000; batch.networkBytes = 15_000_000_000
        batch.destinations = ["/Volumes/G-DRIVE/PikPak", "/Users/example/Downloads"]
        let end = batch.startedAt.addingTimeInterval(750)
        let summary = DownloadReportText.summary(batch, finishedAt: end)
        precondition(summary.hasPrefix("Downloaded 157 files • ") && summary.contains(" • 12m 30s") && summary.hasSuffix(" • 3 already saved"),
            "The status line reads: files, size, time, then files that were already saved")
        let detail = DownloadReportText.detail(batch, finishedAt: end)
        precondition(detail.contains("took 12m 30s") && detail.contains("Saved to: /Volumes/G-DRIVE/PikPak (+1 more folders)")
            && detail.contains("Downloaded: 157 files (") && detail.contains(" • average ") && detail.contains("/s")
            && detail.contains("Already saved: 3 files"), detail)
        batch.completedFiles = 1; batch.skippedFiles = 0; batch.destinations = ["/Volumes/G-DRIVE/PikPak"]
        precondition(DownloadReportText.summary(batch, finishedAt: end).hasPrefix("Downloaded 1 file • ")
            && !DownloadReportText.detail(batch, finishedAt: end).contains("Already saved")
            && !DownloadReportText.detail(batch, finishedAt: end).contains("more folders"),
            "One file is singular, and lines about nothing are left out")
        batch.completedFiles = 0; batch.skippedFiles = 3
        precondition(DownloadReportText.summary(batch, finishedAt: batch.startedAt.addingTimeInterval(5)) == "3 files already saved • 5s",
            "A batch where everything was already saved says so")
        for (seconds, text) in [(0.0, "0s"), (-4, "0s"), (45, "45s"), (59.6, "1m 0s"), (750, "12m 30s"), (11_520, "3h 12m"),
                                (Double.nan, "0s"), (Double.infinity, "0s")] {
            precondition(DownloadReportText.duration(seconds) == text, "\(seconds) should read \(text)")
        }
        print("PASS download report text: status line, details, singular and already-saved wording, and bounded durations")
    }

    static func terminalTransferStates() {
        for cancelled in [false, true] {
            for paused in [false, true] {
                precondition(DownloadTransferPresentation.title(.completed, cancelled: cancelled, paused: paused) == "Complete")
                precondition(DownloadTransferPresentation.title(.skipped, cancelled: cancelled, paused: paused) == "Already saved")
                precondition(DownloadTransferPresentation.title(.failed, cancelled: cancelled, paused: paused)
                    == (cancelled ? "Cancelled" : paused ? "Paused" : "Failed"))
                precondition(DownloadTransferPresentation.title(.retrying(attempt: 2), cancelled: cancelled, paused: paused)
                    == (cancelled ? "Cancelled" : paused ? "Paused" : "Waiting to retry"))
                for state in [DownloadTransferState.failed, .stopped] {
                    precondition(DownloadTransferPresentation.title(state, cancelled: cancelled, paused: paused,
                        automaticRetry: "Retrying automatically")
                        == (cancelled ? "Cancelled" : paused ? "Paused" : "Waiting to retry"))
                    precondition(DownloadTransferPresentation.title(state, cancelled: cancelled, paused: paused,
                        automaticRetry: "Retry queued")
                        == (cancelled ? "Cancelled" : paused ? "Paused" : "Retry queued"))
                }
            }
        }
        precondition(DownloadTransferPresentation.title(.downloading, cancelled: false, paused: true) == "Paused")
        print("PASS terminal transfer states and retry waiting respect Pause and Cancel presentation flags")
    }

    static func discoveredDownloadTotals() {
        let states: [DownloadRunState] = [.ready, .scanning, .downloading, .stopping, .stopped, .failed, .completed]
        for state in states {
            precondition(DownloadProgressPresentation.waitingForDiscovery(state: state,
                totalsIncomplete: true) == (state == .completed))
            precondition(!DownloadProgressPresentation.waitingForDiscovery(state: state, totalsIncomplete: false))
            for fraction: Double? in [nil, 0, 0.25, 0.99, 1] {
                precondition(DownloadProgressPresentation.percentage(fraction: fraction,
                    state: state, totalsIncomplete: true) == "—",
                    "A partial discovery denominator cannot establish a whole-selection percentage")
            }
            precondition(DownloadProgressPresentation.percentage(fraction: nil, state: state, totalsIncomplete: true,
                estimatedFraction: 1.25 / 2.98) == "≈41%",
                "A cached whole-selection estimate shows approximate progress even while discovering or waiting")
            precondition(DownloadProgressPresentation.remaining(state: state, totalsIncomplete: true,
                bytes: "900 GB", duration: "4h 20m") == "Discovering total size… • Calculating time…",
                "An unfinished traversal cannot establish remaining bytes or an ETA, including when held or interrupted")
        }
        for state in states {
            precondition(DownloadProgressPresentation.remaining(state: state, totalsIncomplete: true,
                bytes: "900 GB", duration: "4h 20m", estimatedBytes: "220 GB", estimatedDuration: "3h 10m")
                == "≈ 220 GB left • ~3h 10m", "A cached folder estimate stands in for the unknown remainder, marked approximate")
            precondition(DownloadProgressPresentation.remaining(state: state, totalsIncomplete: true,
                bytes: nil, duration: nil, estimatedBytes: "220 GB", estimatedDuration: nil) == "≈ 220 GB left • Calculating time…",
                "Before a transfer rate is available the estimated remainder keeps an explicit time placeholder")
        }
        precondition(DownloadProgressPresentation.remaining(state: .downloading, totalsIncomplete: false,
            bytes: "900 GB", duration: "4h 20m", estimatedBytes: "220 GB", estimatedDuration: "3h 10m")
            == "900 GB left • 4h 20m", "Once discovery finishes the exact remainder replaces any estimate")
        precondition(DownloadProgressPresentation.percentage(fraction: 0.1234,
            state: .downloading, totalsIncomplete: false) == "12%")
        precondition(DownloadProgressPresentation.stateTitle(state: .completed,
            totalsIncomplete: true) == "Waiting for remaining files")
        precondition(DownloadProgressPresentation.completedSpeedTitle(totalsIncomplete: true) == "Waiting…")
        precondition(DownloadProgressPresentation.stateTitle(state: .completed, totalsIncomplete: false) == "Complete")
        precondition(DownloadProgressPresentation.completedSpeedTitle(totalsIncomplete: false) == "Finished")
        precondition(DownloadProgressPresentation.stateTitle(state: .stopped, totalsIncomplete: true) == "Stopped")
        precondition(DownloadProgressPresentation.stateTitle(state: .downloading, totalsIncomplete: true) == "Discovering files")
        precondition(DownloadProgressPresentation.percentage(fraction: 1,
            state: .completed, totalsIncomplete: false) == "100%")
        precondition(DownloadProgressPresentation.percentage(fraction: nil,
            state: .scanning, totalsIncomplete: false) == "…")
        precondition(DownloadProgressPresentation.remaining(state: .downloading, totalsIncomplete: false,
            bytes: "900 GB", duration: "4h 20m") == "900 GB left • 4h 20m")
        precondition(DownloadProgressPresentation.remaining(state: .downloading, totalsIncomplete: false,
            bytes: "900 GB", duration: nil) == "900 GB left • Calculating time…")
        precondition(DownloadProgressPresentation.remaining(state: .completed, totalsIncomplete: false,
            bytes: nil, duration: nil) == "0 B left")
        precondition(DownloadProgressPresentation.remaining(state: .ready, totalsIncomplete: false,
            bytes: nil, duration: nil) == "—")
        print("PASS discovered totals: cached whole-size estimates show approximate percentages, unknown totals stay unknown, and exact completion remains available")
    }

    static func sharedLinkIdentity() {
        let first = " HTTPS://EXAMPLE.COM/s/CaseSensitive?pwd=AbC&token=%2FAa "
        let folded = "https://example.com/s/CaseSensitive?pwd=AbC&token=%2FAa"
        precondition(SharedLinkIdentity.equivalent(first, folded))
        precondition(!SharedLinkIdentity.equivalent(folded, "https://example.com/s/casesensitive?pwd=AbC&token=%2FAa"))
        precondition(!SharedLinkIdentity.equivalent(folded, "https://example.com/s/CaseSensitive?pwd=abc&token=%2FAa"))
        precondition(!SharedLinkIdentity.equivalent(folded, "https://example.com/s/CaseSensitive?pwd=AbC&token=%2Faa"))
        precondition(SharedLinkIdentity.key(" Generated Access Code ") == "Generated Access Code")
        print("PASS share identity folds DNS/scheme and preserves case-sensitive path/query/access-code bytes")
    }

    static func textBoundaries() {
        let utf8 = Data("prefix 😀".utf8)
        for missing in 1...3 {
            let decoded = TextPreviewDecoder.decode(Data(utf8.dropLast(missing)), responseEncodingName: "utf-8", wasTruncated: true)
            precondition(decoded?.encodingName == "UTF-8" && decoded?.text == "prefix ")
        }
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
            var data = Data(encoding == .utf16LittleEndian ? [0xff, 0xfe] : [0xfe, 0xff])
            data.append("prefix 😀".data(using: encoding)!)
            for missing in 1...3 {
                let decoded = TextPreviewDecoder.decode(Data(data.dropLast(missing)), responseEncodingName: nil, wasTruncated: true)
                precondition(decoded?.encodingName.hasPrefix("UTF-16") == true && decoded?.text == "prefix ")
            }
        }
        let malformedUTF8 = Data([0x61, 0xff, 0x62])
        precondition(TextPreviewDecoder.decode(malformedUTF8, responseEncodingName: "utf-8", wasTruncated: true)?.encodingName != "UTF-8",
                     "A malformed interior byte followed by valid text cannot be repaired as a clipped suffix")
        let continuation = Data([0x61, 0x80])
        precondition(TextPreviewDecoder.decode(continuation, responseEncodingName: "utf-8", wasTruncated: true)?.encodingName != "UTF-8")
        let lowSurrogate = Data([0xff, 0xfe, 0x61, 0x00, 0x00, 0xdc])
        precondition(TextPreviewDecoder.decode(lowSurrogate, responseEncodingName: nil, wasTruncated: true)?.encodingName.hasPrefix("UTF-16") != true,
                     "A standalone low surrogate cannot begin an incomplete scalar")
        let ordinary = TextPreviewDecoder.decode(Data("valid text".utf8), responseEncodingName: "utf-8", wasTruncated: true)
        precondition(ordinary?.text == "valid text")
        print("PASS clipped UTF-8/UTF-16 scalars preserve complete prefix; interior malformed data is not repaired by suffix trimming")
    }

    static func displayBounds() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0] {
            precondition(SafeDisplayNumber.integer(value) == 0 && SafeDisplayNumber.bytes(value) == 0)
        }
        precondition(SafeDisplayNumber.integer(Double(Int.max)) == Int.max)
        precondition(SafeDisplayNumber.integer(Double.greatestFiniteMagnitude) == Int.max)
        precondition(SafeDisplayNumber.bytes(Double(UInt64.max)) == UInt64.max)
        precondition(SafeDisplayNumber.bytes(Double.greatestFiniteMagnitude) == UInt64.max)
        precondition(SafeDisplayNumber.integer(12.9) == 12 && SafeDisplayNumber.integer(12.9, rounding: .up) == 13)
        precondition(SafeDisplayNumber.bytes(12.9) == 13)
        precondition(SafeDisplayNumber.integer(Double(Int.max).nextDown) >= 0)
        precondition(SafeDisplayNumber.bytes(Double(UInt64.max).nextDown) > 0)
        print("PASS display conversions clamp NaN, infinities, negatives and rounded integer upper bounds")
    }

    static func processOutputBounds() {
        let output = ProcessOutputBuffer(maximumBytes: 8)
        output.append(Data("ab".utf8)); output.append(Data("cdefghijkl".utf8))
        precondition(output.string() == "efghijkl")
        output.append(Data(repeating: 65, count: 1 << 20))
        precondition(output.string() == "AAAAAAAA" && output.string().utf8.count == 8)
        let empty = ProcessOutputBuffer(maximumBytes: 0)
        empty.append(Data("discarded".utf8)); precondition(empty.string().isEmpty)
        print("PASS process diagnostic buffer retains only its bounded trailing bytes")
    }

    static func processLines() async throws {
        let pipe = Pipe(), ordered = OrderedProcessLines()
        let delivered = RootAuditValues<[String]>([]), queue = DispatchQueue(label: "RootAuditOrderedLines")
        func deliver(_ lines: [String]) { queue.async { delivered.update { $0.append(contentsOf: lines) } } }
        let multibyte = Data("二".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\n".utf8) + multibyte.prefix(1))
        ordered.read(pipe.fileHandleForReading, deliver: deliver)
        try pipe.fileHandleForWriting.write(contentsOf: Data(multibyte.dropFirst()) + Data("\nthird\nfinal".utf8))
        try pipe.fileHandleForWriting.close()
        ordered.finish(pipe.fileHandleForReading) { lines in
            deliver(lines)
            queue.async { delivered.update { $0.append("EOF") } }
        }
        ordered.finish(pipe.fileHandleForReading, deliver: { _ in preconditionFailure("EOF must complete once") })
        ordered.read(pipe.fileHandleForReading, deliver: { _ in preconditionFailure("Closed stream must not replay") })
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        precondition(delivered.snapshot == ["first", "二", "third", "final", "EOF"])
        try pipe.fileHandleForReading.close()
        print("PASS ordered process delivery joins split UTF-8, flushes trailing EOF once and queues completion after every line")
    }

    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Generated Finder promise fixture timed out")
    }

    @MainActor static func queuedPromiseCancellation() async throws {
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent("RootAuditPromise-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper.py")
        try #"""
        #!/usr/bin/python3
        import os,pathlib,sys,time
        root=pathlib.Path(os.environ['ROOT_AUDIT_DIRECTORY']); label=os.environ['ROOT_AUDIT_LABEL']
        output=pathlib.Path(sys.argv[sys.argv.index('--output')+1])
        (root/('started-'+label)).write_text(str(output))
        while not (root/'release').exists(): time.sleep(.01)
        (output/(label+'.bin')).write_bytes(b'generated fixture')
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let coordinator = CloudDownloadPromiseCoordinator(), completions = RootAuditValues<[String: Bool]>([:])
        var providers: [NSItemProvider] = [], progress: [Progress] = []
        for label in ["first", "second", "queued"] {
            let payload = CloudDownloadPromisePayload(promisedName: label + ".bin", remotePaths: ["/generated-" + label],
                wrapsSelectionInFolder: false, engineURL: helper,
                environment: ["ROOT_AUDIT_DIRECTORY": root.path, "ROOT_AUDIT_LABEL": label], jobs: 1,
                onStart: {}, onFinish: { _ in })
            let provider = coordinator.makeProvider(fileType: "public.data", payload: payload)
            providers.append(provider)
            let request = provider.loadFileRepresentation(forTypeIdentifier: "public.data") { _, error in
                completions.update { $0[label] = error == nil }
            }
            progress.append(request)
            if label == "second" {
                try await wait { manager.fileExists(atPath: root.appendingPathComponent("started-first").path)
                    && manager.fileExists(atPath: root.appendingPathComponent("started-second").path) }
            }
        }
        progress[2].cancel()
        try Data().write(to: root.appendingPathComponent("release"))
        try await wait { completions.snapshot.count == 3 }
        precondition(completions.snapshot["first"] == true && completions.snapshot["second"] == true)
        precondition(completions.snapshot["queued"] == false)
        precondition(!manager.fileExists(atPath: root.appendingPathComponent("started-queued").path),
                     "Canceling a queued Finder promise must prevent helper launch")
        for label in ["first", "second"] {
            let output = try String(contentsOf: root.appendingPathComponent("started-" + label), encoding: .utf8)
            let generated = URL(fileURLWithPath: output)
            guard generated.lastPathComponent.hasPrefix("PikPakDownloader-Drag-") else { preconditionFailure("Unexpected generated fixture output") }
            try? manager.removeItem(at: generated)
        }
        _ = providers
        print("PASS canceling a queued Finder file promise returns cancellation without ever launching its generated helper")
    }
}
