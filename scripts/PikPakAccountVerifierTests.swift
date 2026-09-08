import Foundation

@main
struct PikPakAccountVerifierTests {
    @MainActor
    static func main() async throws {
        let engine = URL(fileURLWithPath: CommandLine.arguments[1])
        let verifier = PikPakAccountVerifier()
        let profile = try await verifier.verify(engineURL: engine, environment: [:])
        precondition(profile.sub == "offline-fixture" && profile.displayName == "Taylor Chen")
        precondition(verifier.processIdentifier == nil)
        for (mode, expected) in [("expired", PikPakAccountError.needsSignIn), ("offline", .unavailable)] {
            do {
                _ = try await verifier.verify(engineURL: engine, environment: ["ACCOUNT_FIXTURE_MODE": mode])
                preconditionFailure("failed account check accepted")
            } catch let error as PikPakAccountError { precondition(error == expected) }
        }
        let task = Task { try await verifier.verify(engineURL: engine, environment: ["ACCOUNT_FIXTURE_MODE": "slow"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(verifier.processIdentifier != nil)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancelled account check succeeded") }
        catch is CancellationError { }
        precondition(verifier.processIdentifier == nil)
        _ = try await verifier.verify(engineURL: engine, environment: [:])
        print("PASS account verifier: real helper success, expired credentials, offline failure, cancellation, process cleanup and subsequent retry")
    }
}
