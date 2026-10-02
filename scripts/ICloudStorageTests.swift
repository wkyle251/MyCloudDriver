import Foundation

@main struct ICloudStorageTests {
    static func rejects(_ value: String) {
        do { _ = try ICloudQuotaParser.remainingBytes(in: value); preconditionFailure("Untrusted quota response was accepted") }
        catch { }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let personal = "37500000000 bytes of quota remaining in personal account\n"
        let personalBytes = try ICloudQuotaParser.remainingBytes(in: personal)
        let zeroBytes = try ICloudQuotaParser.remainingBytes(in: " 0 bytes of quota remaining \n")
        let multipleAccounts = try ICloudQuotaParser.remainingBytes(in: "2 bytes of quota remaining in enterprise account\n" + personal)
        precondition(personalBytes == 37_500_000_000 && zeroBytes == 0 && multipleAccounts == personalBytes)
        for invalid in ["", "-1 bytes of quota remaining", "1.5 bytes of quota remaining", "2 TB remaining", "Not signed in",
                        "18446744073709551616 bytes of quota remaining", personal + personal,
                        "2 bytes of quota remaining in enterprise account", "123 bytes of quota remaining\n456 bytes of quota remaining in enterprise account",
                        "500 bytes of quota remaining in unknown account", personal + "unexpected output"] { rejects(invalid) }
        print("PASS quota parsing: personal account, legacy format, zero, separate enterprise quota and invalid/ambiguous responses")

        let reader = ICloudQuotaReader(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", personal])
        let readBytes = try await reader.read()
        precondition(readBytes == 37_500_000_000)
        precondition(reader.processIdentifier == nil)
        let badOutput = ICloudQuotaReader(executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", String(repeating: "x", count: 17_000)])
        do { _ = try await badOutput.read(); preconditionFailure("Oversized response accepted") }
        catch ICloudStorageError.invalidResponse { }
        let missing = ICloudQuotaReader(executableURL: URL(fileURLWithPath: "/nonexistent/MyCloudDriver-quota-test"))
        do { _ = try await missing.read(); preconditionFailure("Missing command succeeded") }
        catch ICloudStorageError.unavailable { }
        let timeout = ICloudQuotaReader(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeoutNanoseconds: 40_000_000)
        let started = Date()
        do { _ = try await timeout.read(); preconditionFailure("Quota timeout ignored") }
        catch ICloudStorageError.timedOut { }
        precondition(Date().timeIntervalSince(started) < 3 && timeout.processIdentifier == nil)
        let cancelled = ICloudQuotaReader(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let cancellation = Task { try await cancelled.read() }
        try await Task.sleep(nanoseconds: 40_000_000); cancellation.cancel()
        do { _ = try await cancellation.value; preconditionFailure("Quota cancellation ignored") }
        catch is CancellationError { }
        precondition(cancelled.processIdentifier == nil)
        print("PASS bounded read-only process: successful output, missing command, oversized output, timeout and cancellation")

        var calls = 0
        let model = ICloudStorageModel(fetch: { calls += 1; try await Task.sleep(nanoseconds: 30_000_000); return 123 })
        let request = model.refresh()
        precondition(model.isRefreshing)
        _ = model.refresh(force: true)
        await request?.value
        precondition(calls == 1 && model.remainingBytes == 123 && model.checkedAt != nil && !model.isRefreshing)
        precondition(model.refresh() == nil, "Tab changes should use the recent result")
        await model.refresh(force: true)?.value
        precondition(calls == 2)
        model.clear(); precondition(model.remainingBytes == nil && model.checkedAt == nil)
        var response = 1
        let switching = ICloudStorageModel(fetch: {
            let value = response
            try? await Task.sleep(nanoseconds: value == 1 ? 120_000_000 : 10_000_000)
            return UInt64(value)
        })
        let stale = switching.refresh()
        try await Task.sleep(nanoseconds: 10_000_000)
        switching.clear(); response = 2
        await switching.refresh()?.value; await stale?.value
        precondition(switching.remainingBytes == 2, "A cancelled old connection must not overwrite a new result")
        var fail = false
        let failures = ICloudStorageModel(fetch: {
            if fail { throw ICloudStorageError.unavailable }; return 321
        })
        await failures.refresh()?.value; fail = true
        await failures.refresh(force: true)?.value
        precondition(failures.remainingBytes == nil && failures.checkedAt == nil && failures.errorMessage != nil)
        precondition(failures.refresh() == nil, "An unavailable service should not be polled by every view update")
        fail = false; await failures.refresh(force: true)?.value
        precondition(failures.remainingBytes == 321 && failures.errorMessage == nil)
        print("PASS refresh deduplication, caching, explicit retry, stale-result cancellation and truthful error state")

        if CommandLine.arguments.contains("--live") {
            let system = ICloudQuotaReader()
            let remaining = try await system.read()
            print("PASS live macOS iCloud query: \(remaining) bytes available")
        }
    }
}
