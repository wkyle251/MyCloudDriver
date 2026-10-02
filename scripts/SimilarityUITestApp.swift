import AppKit
import SwiftUI

/// Synthetic fixture using production results, outline and Quick Look views.
/// It does not load accounts or read a user's Photos library.
@main @MainActor final class SimilarityUITestApp: NSObject, NSApplicationDelegate {
    private let coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-SimilarityDesign-\(UUID().uuidString)")
    private var fixtureFiles: [SimilarityFile] = []
    private var browserWindow: NSWindow?
    private var sessionManager: WorkspaceSessionManager?
    private var downloadTimer: Timer?
    private let suite = "com.wky.SimilarityActionsQA.\(UUID().uuidString)"
    static func main() {
        let app = NSApplication.shared, delegate = SimilarityUITestApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["Plans/Garden proposal.txt", "Plans/Garden proposal – revised.txt", "Notes/Planting notes.txt", "Photos/Garden.png", "Photos/Garden copy.png", "Archive/Private.pdf", "Notes/Shopping list.txt"]
        for (index, name) in names.enumerated() {
            let url = directory.appendingPathComponent(name)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if url.pathExtension == "png" {
                let image = NSImage(size: .init(width: 480, height: 320)); image.lockFocus()
                NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.83, alpha: 1).setFill(); NSRect(x: 0,y: 0,width: 480,height: 320).fill()
                NSColor(calibratedRed: 0.30, green: 0.60, blue: 0.45, alpha: 1).setFill()
                let path = NSBezierPath(); path.move(to: .init(x: 20,y: 30)); path.line(to: .init(x: 240,y: 250)); path.line(to: .init(x: 460,y: 30)); path.close(); path.fill()
                image.unlockFocus()
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try! rep.representation(using: .png, properties: [:])!.write(to: url)
            } else { try! "Garden proposal\n\nFlowers, trees and a small pond.\n\nRevision \(index).".write(to: url, atomically: true, encoding: .utf8) }
            fixtureFiles.append(.init(id: "file-\(index)", name: url.lastPathComponent, path: "/Project Files/" + name,
                bytes: UInt64(index == 3 || index == 4 ? 2_891_202 : 12_340 + index * 921), family: url.pathExtension == "png" ? "image" : "text",
                localPath: url.path, cloudId: nil, ancestors: [], state: index == 5 ? "unsupported" : "ready"))
        }
        coordinator.source = .local; coordinator.local.localURLs = [directory]
        let defaults = UserDefaults(suiteName: suite)!
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false, localRootURL: directory)
        let sessions = WorkspaceSessionManager(initialHub: hub)
        sessionManager = sessions
        let browser = NSWindow(contentRect: .init(x: 80, y: 80, width: 1160, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        browser.isReleasedWhenClosed = false
        browser.contentView = NSHostingView(rootView: WorkspaceSessionRoot(hub: hub, manager: sessions))
        browserWindow = browser; sessions.register(browser, hub: hub)
        coordinator.revealInBrowser = { [weak hub, weak sessions] _, file in
            guard let hub else { return }
            hub.open(.local); hub.local.revealSimilarityFile(file)
            sessions?.activateBrowser(in: hub)
        }
        // UI-only simulated response. No files are moved or deleted through
        // this fixture UI; file-action tests exercise the actual providers.
        coordinator.moveToTrash = { [weak self] file in
            guard let self, let path = file.localPath, path.hasPrefix(self.directory.path + "/") else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 350_000_000)
            if file.id == "file-5" { throw CloudDriveError.message("The synthetic provider could not move this file. Nothing was deleted.") }
        }
        coordinator.keepSmallest = { plan in
            try await Task.sleep(nanoseconds: 350_000_000)
            // Deliberately simulate the acknowledgement; the UI does not delete fixtures.
            return plan.removalIDs
        }
        coordinator.chooseFolderScope = { [weak self] in self?.showScopePicker() }
        coordinator.local.setFixtureReport(.init(source: .local, scope: ["Project Files"], status: "partial", threshold: 0.9,
            scannedFiles: 7, analysedFiles: 6, skippedFiles: 1, downloadedBytes: 0, totalGroups: 1,
            groups: [.init(id: "identical-images", matchKind: "byte_identical", family: "image", minimumScore: nil, memberCount: 2, members: [fixtureFiles[3], fixtureFiles[4]])],
            issues: [.init(path: fixtureFiles[5].path, reason: "Password-protected PDF. Content could not be analysed.")],
            truncated: false, coverage: "One file was skipped. Comparison coverage is exhaustive for analysed files.", elapsedSeconds: 24,
            files: fixtureFiles, scoresRetained: 11, unsupportedFiles: 1, failedFiles: 0,
            issueSummary: [.init(category: "unsupported", reason: "Password-protected PDF. Content could not be analysed.", count: 1)]))
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Similarity Design Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: ""), fixtureMenu = NSMenu(title: "Fixture")
        for (title, action) in [("Show Results", #selector(showResults)), ("Toggle Appearance", #selector(toggleAppearance)), ("Minimum Window Size", #selector(minimumSize)), ("Show Pair Progress", #selector(showProgress)), ("Show Encoding Progress", #selector(showEncoding)), ("Show Live Discovery", #selector(showDiscovery)), ("Show Folder Picker", #selector(showScopePicker)), ("Show Cancelled Scan", #selector(showCancelled)), ("Show Cloud Download Progress", #selector(showCloudDownloads))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; fixtureMenu.addItem(item)
        }
        fixtureItem.submenu = fixtureMenu; menu.addItem(fixtureItem); NSApp.mainMenu = menu
        coordinator.present(source: .local)
        Task {
            while coordinator.local.results.isIndexing { try? await Task.sleep(nanoseconds: 10_000_000) }
            for index in [0,1,2,6] {
                let entries = [0,1,2,6].filter { $0 != index }.map { other in
                    SimilarityScoreRow.Entry(fileId: "file-\(other)", score: index == 6 || other == 6 ? 0.061 : (index == 2 || other == 2 ? 0.874 : 0.963))
                }
                coordinator.local.results.setFixtureRow(.init(fileId: "file-\(index)", entries: entries, unavailable: ["incompatible_profile":2,"file_unavailable":1], omitted: 0))
            }
            for index in [3,4] { coordinator.local.results.setFixtureRow(.init(fileId: "file-\(index)", entries: [.init(fileId: "file-\(index == 3 ? 4 : 3)", score: 1)], unavailable: ["incompatible_profile":4,"file_unavailable":1], omitted: 0)) }
            for percent in 5...100 {
                var groups = [SimilarityResultGroup(id: "group:images", members: [fixtureFiles[3], fixtureFiles[4]], minimumScore: nil, identical: true)]
                if percent <= 96 {
                    let members = percent <= 6 ? [0,1,2,6] : percent <= 87 ? [0,1,2] : [0,1]
                    groups.insert(.init(id: "group:text", members: members.map { fixtureFiles[$0] }, minimumScore: percent <= 6 ? 0.061 : percent <= 87 ? 0.874 : 0.963, identical: false), at: 0)
                }
                coordinator.local.results.setFixtureGroups(groups, at: Double(percent) / 100)
            }
            coordinator.local.results.selectNode("group:text")
        }
    }
    @objc private func showResults() { coordinator.present(source: .local) }
    @objc private func toggleAppearance() { NSApp.appearance = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua ? .aqua : .darkAqua) }
    @objc private func minimumSize() { NSApp.windows.first(where: { $0.title == "Find Similar Files" })?.setContentSize(.init(width: 940, height: 740)) }
    @objc private func showProgress() { coordinator.local.setFixtureProgress(["event":"progress", "stage":"comparison", "counts":["files_processed":240,"files_total":240,"files_ready":238,"files_failed":2,"pairs_processed":12800,"pairs_total":28680,"pairs_compared":9200,"scores_retained":9200,"bytes_read":2_591_221_230]]) }
    @objc private func showEncoding() { coordinator.local.setFixtureProgress(["event":"progress", "stage":"analysing", "active":52,
        "work":["fetching":8,"reading":12,"encoding":27,"waiting_memory":5,"waiting_reuse":14,"worker_limit":52,"memory_limit":UInt64(48 * 1_024 * 1_024 * 1_024)],
        "counts":["files_discovered":1593,"files_processed":852,"files_total":1593,"files_ready":800,"files_failed":2,"files_skipped":50,"vectors_encoded":674,"cache_hits":126,"bytes_read":2_591_221_230]]) }
    @objc private func showDiscovery() { coordinator.local.setFixtureProgress(["event":"progress", "stage":"analysing", "discovery_complete":false, "active":8,
        "counts":["files_discovered":5197,"files_processed":1634,"files_total":NSNull(),"files_ready":1632,"files_failed":2,"cache_hits":400,"vectors_encoded":1232,"bytes_read":2_591_221_230]]) }
    @objc private func showCloudDownloads() {
        downloadTimer?.invalidate()
        let downloads: [[String:Any]] = (0..<12).map { index in
            let state = index == 4 ? "waiting_memory" : index == 5 ? "retrying" : index == 6 ? "connecting" : "downloading"
            return ["id":index, "name":index < 3 ? "Summer holiday — camera \(index + 1).mp4" : "IMG_\(5070 + index).HEIC",
                    "received":index < 3 ? 420_000_000 : index < 6 ? 31_000_000 : 0,
                    "total":index < 3 ? 1_073_741_824 : 107_374_182,
                    "speed":state == "downloading" ? (index < 3 ? 8_100_000 : 3_200_000) : 0,
                    "state":state,"attempt":index == 5 ? 2 : 1,"retry_seconds":30]
        }
        coordinator.cloud.cloudRoots = [.init(id: "fixture", name: "Project Photos", path: "/Project Photos", isFolder: true, size: 0, ancestors: [])]
        let event: [String:Any] = ["event":"progress", "stage":"analysing", "discovery_complete":false, "active":43,
            "work":["independent_downloads":true,"fetching":9,"resolving":1,"reading":2,"encoding":32,"ready":12,"waiting_memory":1,"waiting_download":0,"retrying_download":1,"download_limit":16,"worker_limit":52,
                    "original_memory_bytes":UInt64(6 << 30),"original_memory_limit":UInt64(12 << 30),"analysis_memory_bytes":UInt64(16 << 30),"analysis_memory_limit":UInt64(52 << 30),"memory_limit":UInt64(64 << 30)],
            "counts":["files_discovered":621,"files_processed":440,"files_total":NSNull(),"files_ready":440,"files_failed":0,"files_skipped":0,"vectors_encoded":440],
            "downloads":["items":downloads,"total":12,"speed":43_500_000,"forecast_bytes":UInt64(7 << 30),"forecast_seconds":2],
            "downloaded_bytes":592_000_000]
        coordinator.cloud.setFixtureProgress(event)
        downloadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.coordinator.cloud.isRunning else { timer.invalidate(); return }
                self.coordinator.cloud.setFixtureProgress(event)
            }
        }
        coordinator.present(source: .cloud)
    }
    @objc private func showScopePicker() {
        coordinator.scopePicker = SimilarityScopePicker(title: "Choose PikPak Folder", root: .init(id: "", title: "PikPak"), load: { location, _ in
            .init(folders: location.id == "" ? ["Projects", "Photos", "Documents"].map { .init(id:$0, title:$0) } : [])
        }, accept: { _ in })
    }
    @objc private func showCancelled() {
        coordinator.local.setFixtureReport(.init(source: .local, scope: ["Project Files"], status: "cancelled", threshold: 0.9,
            scannedFiles: 7, analysedFiles: 6, skippedFiles: 1, downloadedBytes: 0, totalGroups: 0, groups: [], issues: [], truncated: false,
            coverage: "Cancelled during analysis. No pair comparisons were run.", elapsedSeconds: 72, files: fixtureFiles, scoresRetained: 0))
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        downloadTimer?.invalidate()
        coordinator.close(); browserWindow?.close()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
