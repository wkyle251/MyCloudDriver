import AppKit
import SwiftUI

/// Uses production views with synthetic, separately owned cloud/local data.
/// It never loads the app's account store or sends cloud requests.
@main @MainActor final class SimilarityUITestApp: NSObject, NSApplicationDelegate {
    private let coordinator: FileSimilarityCoordinator
    override init() {
        let coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        coordinator.source = .local
        coordinator.local.localURLs = [URL(fileURLWithPath: "/Users/demo/Documents/Project Files", isDirectory: true)]
        let members = ["Garden proposal.docx", "Garden proposal – revised.pdf", "Planting notes.txt"].enumerated().map { index, name in
            SimilarityFile(id: "document-\(index)", name: name, path: "/Users/demo/Documents/Project Files/\(name)", bytes: UInt64(12_340 + index * 921),
                family: "text", localPath: "/synthetic/\(name)", cloudId: nil, ancestors: [])
        }
        let photos = ["Garden.jpg", "Garden-copy.jpg"].enumerated().map { index, name in
            SimilarityFile(id: "photo-\(index)", name: name, path: "/Users/demo/Pictures/\(name)", bytes: 2_891_202,
                family: "image", localPath: "/synthetic/\(name)", cloudId: nil, ancestors: [])
        }
        coordinator.local.setFixtureReport(SimilarityReport(source: .local, scope: ["/Users/demo/Documents/Project Files"], status: "partial", threshold: 0.9,
            scannedFiles: 128, analysedFiles: 125, skippedFiles: 3, downloadedBytes: 0, totalGroups: 3,
            groups: [SimilarityGroup(id: "documents", matchKind: "similar_content", family: "text", minimumScore: 0.963, memberCount: 3, members: members),
                SimilarityGroup(id: "photos", matchKind: "similar_content", family: "image", minimumScore: 0.997, memberCount: 2, members: photos),
                SimilarityGroup(id: "copies", matchKind: "byte_identical", family: "other", minimumScore: nil, memberCount: 2, members: photos)],
            issues: [SimilarityIssue(path: "/Users/demo/Documents/Archive.zip", reason: "Unsupported content format; checked for identical bytes"),
                SimilarityIssue(path: "/Users/demo/Documents/Private.pdf", reason: "Password-protected PDF"),
                SimilarityIssue(path: "/Users/demo/Documents/Offline.mov", reason: "File is unavailable")],
            truncated: false, coverage: "Source coverage: partial. Comparison coverage: exhaustive for analysed files.", elapsedSeconds: 24))
        coordinator.cloudScope = { _ in [SimilarityCloudRoot(id: "projects", name: "Projects", path: "/Projects", isFolder: true, size: 0, ancestors: [])] }
        coordinator.useBrowserSelection(false)
        if CommandLine.arguments.contains("--progress") || Bundle.main.object(forInfoDictionaryKey: "SimilarityProgressFixture") as? Bool == true {
            let cloud = CommandLine.arguments.contains("--cloud")
            coordinator.source = cloud ? .cloud : .local
            for scan in coordinator.runs {
                let isCloud = scan.source == .cloud
                scan.threshold = 0.05
                scan.setFixtureProgress(["event":"progress", "stage":isCloud ? "downloading" : "analysing", "completed":15, "total":24,
                    "current_file":["name":"Garden walkthrough.mov", "bytes":2_147_483_648], "file_bytes_read":1_207_959_552,
                    "operation":isCloud ? "downloading" : "decoding", "downloaded_bytes":isCloud ? 17_000_000_000 : 0,
                    "counts":["files_ready":isCloud ? 0 : 14, "files_failed":isCloud ? 0 : 1, "similar_pairs":0, "exact_pairs":0]])
            }
        }
        self.coordinator = coordinator
        super.init()
    }
    static func main() {
        let app = NSApplication.shared
        let delegate = SimilarityUITestApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Similarity Design Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        coordinator.present(source: coordinator.source)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { coordinator.close() }
}
