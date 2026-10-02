import Foundation

@main
struct PikPakAccountVerifierFixture {
    static func main() {
        let quota = CommandLine.arguments.dropFirst() == ["quota", "--json", "--with-transfer"]
        guard quota || CommandLine.arguments.dropFirst() == ["account"] else { exit(2) }
        switch ProcessInfo.processInfo.environment["ACCOUNT_FIXTURE_MODE"] {
        case "expired":
            FileHandle.standardError.write(Data("authentication failed: invalid_grant".utf8))
            exit(1)
        case "offline":
            FileHandle.standardError.write(Data("connection timed out".utf8))
            exit(1)
        case "access-rejected":
            FileHandle.standardError.write(Data("HTTP request failed: HTTP status client error (401 Unauthorized) for url (https://fixture.invalid/v1/user/me)".utf8))
            exit(1)
        case "unrelated-number":
            FileHandle.standardError.write(Data("connection timed out at request 4126".utf8))
            exit(1)
        case "invalid-client":
            FileHandle.standardError.write(Data(#"authentication failed: status 400: {"error":"invalid_client"}"#.utf8))
            exit(1)
        case "session-rejected":
            FileHandle.standardError.write(Data("error: PikPak session rejected: fixture credential rejected".utf8))
            exit(1)
        case "slow":
            Thread.sleep(forTimeInterval: 20)
        default: break
        }
        if quota {
            print(#"{"account_id":"offline-fixture","total":1000,"used":100,"transfer":{"cloudDownload":{"total":40000,"used":142},"downstream":{"total":4000,"used":4040},"upload":{"total":1000,"used":72}}}"#)
        } else {
            print(#"{"sub":"offline-fixture","name":"Taylor Chen"}"#)
        }
    }
}
