import AppKit
import SwiftUI

/// Offline production-view fixture. No helper, account or user file is used.
@main @MainActor final class SimilarityAutoMemoryUITestApp: NSObject, NSApplicationDelegate {
    private let coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoMemoryUI-\(UUID().uuidString)")
    static func main() {
        let app = NSApplication.shared, delegate = SimilarityAutoMemoryUITestApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coordinator.local.localURLs = [directory]
        let menu = NSMenu(), item = NSMenuItem(), actions = NSMenu()
        menu.addItem(item); item.submenu = actions
        for (title, selector, key) in [("New Scan", #selector(newScan), "1"),
                                       ("Memory Warning", #selector(warning), "2"),
                                       ("Memory Critical", #selector(critical), "3"),
                                       ("Quit", #selector(NSApplication.terminate(_:)), "q")] {
            let action = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            action.target = selector == #selector(NSApplication.terminate(_:)) ? NSApplication.shared : self
            actions.addItem(action)
        }
        NSApplication.shared.mainMenu = menu
        coordinator.present(source: .local)
    }
    func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: directory) }
    @objc private func newScan() {
        coordinator.local.clearSession(); coordinator.local.localURLs = [directory]
        coordinator.present(source: .local)
    }
    @objc private func warning() { showPressure(2) }
    @objc private func critical() { showPressure(4) }
    private func showPressure(_ level: Int) {
        coordinator.local.setFixtureProgress(["event":"progress", "stage":"analysing", "completed":9, "total":40,
            "counts":["files_discovered":40, "files_processed":9, "files_ready":9],
            "work":["automatic_memory":true, "memory_scheduling":true, "memory_pressure":level,
                "worker_limit":8, "memory_limit":UInt64(2 << 30), "waiting_memory":4,
                "original_memory_bytes":UInt64(512 << 20), "original_memory_limit":UInt64(512 << 20),
                "analysis_memory_bytes":UInt64(1 << 30), "analysis_memory_limit":UInt64(1 << 30),
                "encoding":level == 4 ? 0 : 1, "fetching":0, "reading":0]])
        coordinator.present(source: .local)
    }
}
