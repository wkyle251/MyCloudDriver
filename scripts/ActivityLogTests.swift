import Foundation

@main struct ActivityLogTests {
    static func main() {
        var log = ActivityLogBuffer()
        log.append("Downloading report.bin\nWar")
        log.append("ning: retrying the request\n2026-10-07T05:00:00Z DEBUG connection opened\n")
        log.record("Some downloads were interrupted: File name too long (os error 63)\nCode: DOWNLOAD_FAILED", level: .error)
        precondition(log.entries.count == 4)
        precondition(log.entries.map(\.level) == [.info, .warning, .debug, .error])
        for filter in ActivityLogFilter.allCases {
            let entries = log.entries(matching: filter)
            precondition(entries.count == (filter == .all ? 4 : 1))
            precondition(entries.allSatisfy { filter.includes($0.level) })
        }
        precondition(log.entries(matching: .error).first?.message.contains("Code: DOWNLOAD_FAILED") == true)
        precondition(ActivityLogLevel.inferred(from: "Downloading error-warning.mp4") == .info)
        precondition(ActivityLogLevel.inferred(from: "Could not open the disk") == .error)
        precondition(ActivityLogLevel.inferred(from: "2026-10-07T05:00:00Z INFO pikpak::download_share: Share link unavailable: expired; creating a new share link to download.") == .info)
        log.append("\u{001B}[33m WARN network retry\u{001B}[0m\r\n")
        precondition(log.entries.last?.level == .warning)
        precondition(log.entries.last?.message.contains("\u{001B}") == false)
        // Thousands of ordinary completion messages must not evict the error
        // before the user can choose the Error filter.
        for index in 0..<5_000 { log.append("Saved generated download \(index)\n") }
        precondition(log.entries.count <= 1_500 && log.text.count <= 122_000)
        precondition(log.trimmed && log.errorCount == 1)
        let retainedError = log.entries(matching: .error).first!
        precondition(retainedError.message.contains("File name too long"))
        var huge = ActivityLogBuffer()
        huge.record(String(repeating: "x", count: 200_000), level: .error)
        precondition(huge.text.count < 17_000)
        let revision = log.revision
        log.clear()
        precondition(log.entries.isEmpty && log.text.isEmpty && !log.trimmed)
        precondition(log.latestErrorID == nil && log.revision != revision)
        print("PASS Activity Log: stream fragments, levels, exact filters, multiline errors, bounded history, retained errors and Clear")
    }
}
