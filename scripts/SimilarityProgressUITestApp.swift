import AppKit
import SwiftUI

/// Offline display check. All names, sizes and counters are synthetic.
@main @MainActor final class SimilarityProgressUITestApp: NSObject, NSApplicationDelegate {
    private let coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    private var telemetry: Timer?
    static func main() {
        let app = NSApplication.shared, delegate = SimilarityProgressUITestApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), actions = NSMenu()
        menu.addItem(item); item.submenu = actions
        for (title,action,key) in [("Partial download",#selector(partial),"1"),
            ("All cloud data ready",#selector(ready),"2"),("Counting files",#selector(counting),"3"),
            ("Paused",#selector(paused),"4"),("Waiting for speed",#selector(stalled),"5"),
            ("Quit",#selector(NSApplication.terminate(_:)),"q")] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:key)
            item.target = action == #selector(NSApplication.terminate(_:)) ? NSApplication.shared : self
            actions.addItem(item)
        }
        NSApplication.shared.mainMenu = menu
        coordinator.cloud.cloudRoots = [.init(id:"fixture",name:"Progress test",path:"/Progress test",isFolder:true,size:0,ancestors:[])]
        partial(); coordinator.present(source:.cloud)
    }
    @objc private func partial() { show(ready:100 << 30,complete:true) }
    @objc private func ready() { show(ready:1000 << 30,complete:true) }
    @objc private func counting() { show(ready:100 << 30,complete:false) }
    @objc private func paused() { show(ready:100 << 30,complete:true,paused:true) }
    @objc private func stalled() { show(ready:100 << 30,complete:true,speed:0) }
    private func show(ready:UInt64,complete:Bool,speed:Double = 10 * 1_048_576,paused:Bool = false) {
        telemetry?.invalidate()
        update(ready:ready,complete:complete,speed:speed,paused:paused)
        telemetry = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.update(ready:ready,complete:complete,speed:speed,paused:paused) }
        }
    }
    private func update(ready:UInt64,complete:Bool,speed:Double,paused:Bool) {
        coordinator.cloud.setFixtureProgress(["event":"progress","stage":"analysing","completed":9,"total":10,
            "discovery_complete":complete,"counts":["files_discovered":10,"files_ready":9,"files_processed":9,
                "files_total":10,"files_skipped":0,"files_failed":0,"vectors_encoded":6,"cache_hits":3],
            "cloud_data":["ready_bytes":ready,"total_bytes":UInt64(1000 << 30),"inventory_complete":complete],
            "downloads":["total":1,"omitted":0,"speed":speed,"items":[["id":1,"name":"Example video.mp4",
                "received":UInt64(10 << 30),"total":UInt64(20 << 30),"speed":speed,"state":"downloading"]]],
            "downloaded_bytes":UInt64(600 << 30),"work":["fetching":ready < 1000 << 30 ? 1 : 0,"encoding":1,
                "original_memory_bytes":UInt64(10 << 30),"original_memory_limit":UInt64(40 << 30),
                "analysis_memory_bytes":UInt64(4 << 30),"analysis_memory_limit":UInt64(24 << 30)]],paused:paused)
    }
}
