import AppKit
import SwiftUI

/// Synthetic fixture using production results, outline and Quick Look views.
/// It does not load accounts or read a user's Photos library.
@main @MainActor final class SimilarityUITestApp: NSObject, NSApplicationDelegate {
    private let coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-SimilarityDesign-\(UUID().uuidString)")
    private var fixtureFiles: [SimilarityFile] = []
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
        coordinator.local.setFixtureReport(.init(source: .local, scope: ["Project Files"], status: "partial", threshold: 0.9,
            scannedFiles: 7, analysedFiles: 6, skippedFiles: 1, downloadedBytes: 0, totalGroups: 1,
            groups: [.init(id: "identical-images", matchKind: "byte_identical", family: "image", minimumScore: nil, memberCount: 2, members: [fixtureFiles[3], fixtureFiles[4]])],
            issues: [.init(path: fixtureFiles[5].path, reason: "Password-protected PDF. Content could not be analysed.")],
            truncated: false, coverage: "One file was skipped. Comparison coverage is exhaustive for analysed files.", elapsedSeconds: 24,
            files: fixtureFiles, scoresRetained: 11))
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Similarity Design Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: ""), fixtureMenu = NSMenu(title: "Fixture")
        for (title, action) in [("Toggle Appearance", #selector(toggleAppearance)), ("Minimum Window Size", #selector(minimumSize)), ("Show Pair Progress", #selector(showProgress))] {
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
            coordinator.local.results.select("file-0")
        }
    }
    @objc private func toggleAppearance() { NSApp.appearance = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua ? .aqua : .darkAqua) }
    @objc private func minimumSize() { NSApp.keyWindow?.setContentSize(.init(width: 900, height: 710)) }
    @objc private func showProgress() { coordinator.local.setFixtureProgress(["event":"progress", "stage":"comparison", "counts":["files_processed":240,"files_total":240,"files_ready":238,"files_failed":2,"pairs_processed":12800,"pairs_total":28680,"pairs_compared":9200,"scores_retained":9200,"bytes_read":2_591_221_230]]) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { coordinator.close(); try? FileManager.default.removeItem(at: directory) }
}
