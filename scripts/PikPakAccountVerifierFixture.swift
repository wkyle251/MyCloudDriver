import Foundation

@main
struct PikPakAccountVerifierFixture {
    static func main() {
        guard CommandLine.arguments.dropFirst() == ["account"] else { exit(2) }
        switch ProcessInfo.processInfo.environment["ACCOUNT_FIXTURE_MODE"] {
        case "expired":
            FileHandle.standardError.write(Data("authentication failed: invalid_grant".utf8))
            exit(1)
        case "offline":
            FileHandle.standardError.write(Data("connection timed out".utf8))
            exit(1)
        case "slow":
            Thread.sleep(forTimeInterval: 20)
        default: break
        }
        print(#"{"sub":"offline-fixture","name":"Taylor Chen"}"#)
    }
}
