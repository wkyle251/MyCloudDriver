// Deterministic offline stand-in for the helper, used by unit and UI tests.
import Foundation

@main
struct FixtureEngine {
    static func main() throws {
        func emit(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        func progress(_ count: Int, _ folders: Int) -> [String: Int] {
            ["indexed_items": count, "scanned_folders": folders,
             "discovered_folders": 2, "failed_folders": 0]
        }
        Thread.sleep(forTimeInterval: 0.2)
        try emit(["event": "page", "parent_id": "", "ancestors": [],
                  "items": [["id": "reports", "name": "Reports", "kind": "drive#folder", "size": 0]],
                  "progress": progress(1, 1)])
        Thread.sleep(forTimeInterval: 0.7)
        let items = (0..<240).map { i in
            ["id": "report-\(i)", "name": String(format: "Report %03d.txt", i),
             "kind": "drive#file", "size": 128] as [String: Any]
        }
        try emit(["event": "page", "parent_id": "reports",
                  "ancestors": [["id": "reports", "name": "Reports"]],
                  "items": items, "progress": progress(241, 2)])
        Thread.sleep(forTimeInterval: 1.5)
        try emit(["event": "finished", "progress": progress(241, 2)])
    }
}
