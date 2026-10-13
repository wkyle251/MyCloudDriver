import Foundation

@main
struct CloudExtractionFixtureEngine {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 4, let requestIndex = args.firstIndex(of: "--request-file") else { exit(2) }
        let requestURL = URL(fileURLWithPath: args[requestIndex + 1])
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as! [String: Any]
        let id = request["file_id"] as! String
        let expectedPassword = id == "protected-b" ? "fixture-second" : "fixture-password"
        precondition(!args.contains("fixture-password"))
        precondition(!ProcessInfo.processInfo.environment.keys.contains(where: { $0.contains("TOKEN") }))
        let permissions = try FileManager.default.attributesOfItem(atPath: requestURL.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        if args[1] == "archive-inspect" {
            Thread.sleep(forTimeInterval: id == "cancel" ? 2 : 0.25)
            if id == "permission-always" || (id.hasPrefix("permission") && ProcessInfo.processInfo.environment["MYCLOUD_ARCHIVE_CONNECTION"] != "desktop-oauth") {
                FileHandle.standardError.write(Data("API error 403: {\"error_code\":7,\"error_description\":\"Permission denied\"}\n".utf8))
                exit(1)
            }
            let needsPassword = id.hasPrefix("protected") && request["password"] as? String != expectedPassword
            let result: [String: Any] = [
                "title": "\(id).zip", "status": needsPassword ? "PASSWORD_REQUIRED" : "OK",
                "status_text": needsPassword ? "Enter the archive password" : "Ready",
                "ready": !needsPassword, "required_password": needsPassword,
                "entries": needsPassword ? [] : [["index": 0, "name": "sample.txt", "path": "sample.txt", "kind": "drive#file", "size": 4096],
                                                   ["index": 1, "name": "Folder", "path": "Folder/", "kind": "drive#folder", "size": 8192]]
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
            return
        }
        if id.hasPrefix("protected"), request["password"] as? String != expectedPassword { exit(3) }
        if id == "fail" {
            FileHandle.standardError.write(Data("API error 503: fixture extraction failure\n".utf8))
            exit(1)
        }
        for step in 1...6 {
            Thread.sleep(forTimeInterval: id.hasPrefix("ui-") ? 12 : id == "slow" ? 0.3 : 0.18)
            let line = "@pikpak-archive-progress:{\"event\":\"progress\",\"progress\":\(step * 15),\"phase\":\"PHASE_TYPE_RUNNING\"}\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let result: [String: Any] = ["archive_file_id": id, "output_file_id": "output-\(id)", "progress": 100, "phase": "PHASE_TYPE_COMPLETE"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
