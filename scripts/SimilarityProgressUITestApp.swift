import AppKit
import SwiftUI

/// Offline display check. All names, sizes and counters are synthetic.
@main @MainActor final class SimilarityProgressUITestApp: NSObject, NSApplicationDelegate {
    private let coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    private var telemetry: Timer?
    private var processed: UInt64 = 100
    private var compared: UInt64 = 1_000
    private var comparisonMode = false
    private var acquired: UInt64 = 0
    private var hashed: UInt64 = 0
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
            ("Comparing files",#selector(comparison),"6"),
            ("Reading a network disk",#selector(diskReading),"7"),
            ("Hashing in Analysis RAM",#selector(diskHashing),"8"),
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
    @objc private func comparison() { show(ready:1000 << 30,complete:true,comparing:true) }
    @objc private func diskReading() { showDisk(hashing:false) }
    @objc private func diskHashing() { showDisk(hashing:true) }
    private func showDisk(hashing:Bool) {
        telemetry?.invalidate()
        acquired = max(acquired, 1_700_000_000); hashed = 0
        coordinator.local.localURLs = [URL(fileURLWithPath:"/Generated network drive/Garden videos")]
        updateDisk(hashing:hashing); coordinator.present(source:.local)
        telemetry = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.updateDisk(hashing:hashing) }
        }
    }
    private func updateDisk(hashing:Bool) {
        if hashing { hashed += 100 << 20 } else { acquired += 16 << 20 }
        coordinator.local.setFixtureProgress(["event":"progress","stage":"analysing","completed":9,"total":91,
            "discovery_complete":true,"counts":["files_discovered":91,"files_processed":9,"files_ready":9,
                "bytes_read":acquired + hashed,"bytes_hashed":hashed],
            "work":["reading":hashing ? 0 : 4,"hashing":hashing ? 1 : 0,"encoding":0,
                "ready":0,"waiting_read":78,"original_bytes_read":acquired,
                "original_memory_bytes":hashing ? 0 : UInt64(1700 << 20),"original_memory_limit":UInt64(5 << 30),
                "analysis_memory_bytes":hashing ? UInt64(2 << 30) : 0,"analysis_memory_limit":UInt64(35 << 30),
                "memory_scheduling":true,"worker_limit":64,"memory_limit":UInt64(40 << 30)],
            "active":hashing ? 1 : 4])
    }
    private func show(ready:UInt64,complete:Bool,speed:Double = 10 * 1_048_576,paused:Bool = false,comparing:Bool = false) {
        telemetry?.invalidate()
        comparisonMode = comparing
        update(ready:ready,complete:complete,speed:speed,paused:paused)
        telemetry = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.update(ready:ready,complete:complete,speed:speed,paused:paused) }
        }
    }
    private func update(ready:UInt64,complete:Bool,speed:Double,paused:Bool) {
        if !paused && speed > 0 { if comparisonMode { compared += 100 } else { processed = min(990,processed + 10) } }
        coordinator.cloud.setFixtureProgress(["event":"progress","stage":comparisonMode ? "comparison" : "analysing",
            "completed":comparisonMode ? compared : processed,"total":comparisonMode ? 100_000 : 1_000,
            "discovery_complete":complete,"counts":["files_discovered":1_000,"files_ready":processed,"files_processed":processed,
                "files_total":1_000,"files_skipped":0,"files_failed":0,"vectors_encoded":processed * 2 / 3,"cache_hits":processed / 3,
                "pairs_compared":compared,"pairs_total":100_000],
            "cloud_data":["ready_bytes":ready,"total_bytes":UInt64(1000 << 30),"inventory_complete":complete],
            "downloads":["total":1,"omitted":0,"speed":speed,"items":[["id":1,"name":"Example video.mp4",
                "received":UInt64(10 << 30),"total":UInt64(20 << 30),"speed":speed,"state":"downloading"]]],
            "downloaded_bytes":UInt64(600 << 30),"work":["fetching":ready < 1000 << 30 ? 1 : 0,"encoding":1,
                "original_memory_bytes":UInt64(10 << 30),"original_memory_limit":UInt64(40 << 30),
                "analysis_memory_bytes":UInt64(4 << 30),"analysis_memory_limit":UInt64(24 << 30)]],paused:paused)
    }
}
