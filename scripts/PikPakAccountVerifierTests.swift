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
        for (mode, expected) in [("expired", PikPakAccountError.needsSignIn), ("offline", .unavailable),
                                 ("access-rejected", .unavailable), ("unrelated-number", .unavailable), ("invalid-client", .unavailable),
                                 ("session-rejected", .needsSignIn)] {
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
        for rejected in [#"error: authentication failed: status 400: {"error": "invalid_grant"}"#,
                         #"authentication failed: status 401: {"error_code":4126}"#] {
            precondition(PikPakSessionFailure.requiresSignIn(rejected))
        }
        print("PASS account verifier: explicit credential rejection, recoverable access errors, offline/client errors, cancellation, process cleanup and retry")
    }
}
