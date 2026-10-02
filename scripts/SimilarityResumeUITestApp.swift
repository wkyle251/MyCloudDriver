import AppKit
import Foundation

/// Production scan UI with synthetic files and no account credentials.
@main @MainActor final class SimilarityResumeUITestApp: NSObject, NSApplicationDelegate {
    let coordinator=FileSimilarityCoordinator(activity:FinderTaskActivityStore())
    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["MYCLOUD_QA_DATA"] ?? "/private/tmp/MyCloudResourceEditingQAData")
    var finishDiscovery = false
    static func main() {
        let app=NSApplication.shared, delegate=SimilarityResumeUITestApp()
        app.delegate=delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu=NSMenu(), appItem=NSMenuItem(), appMenu=NSMenu()
        appMenu.addItem(withTitle:"Find Similar Files",action:#selector(openScan),keyEquivalent:"f")
        appMenu.addItem(withTitle:"Continue Sample Discovery",action:#selector(continueDiscovery),keyEquivalent:"d")
        appMenu.addItem(withTitle:"Quit Recovery QA",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu=appMenu; menu.addItem(appItem); NSApp.mainMenu=menu
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let resources=URL(fileURLWithPath:ProcessInfo.processInfo.environment["MYCLOUD_QA_RESOURCES"] ?? "/Users/wky/Work/PikPakDownloader/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources")
        let text=String(repeating:"A garden with trees, flowers and paths through the green lawn. ",count:30)
        for name in ["Garden plan.txt","Planting notes.txt"] {
            let file=root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:file.path) { try! text.write(to:file,atomically:true,encoding:.utf8) }
        }
        coordinator.configuration={ [self] _ in
            SimilarityConfiguration(executable:resources.appendingPathComponent("pikpak"),models:resources.appendingPathComponent("FileTwinModels"),
                worker:resources.appendingPathComponent("filetwin-worker"),dataDirectory:root.appendingPathComponent("data"),
                temporaryDirectory:root.appendingPathComponent("temp"),environment:[:])
        }
        let scan=coordinator.local
        scan.localURLs=[root]; scan.families=["text"]
        scan.streamExternalSources={ [self] emit in
            for (index,name) in ["Garden plan.txt","Planting notes.txt"].enumerated() {
                if index == 1 {
                    while !finishDiscovery { try await Task.sleep(nanoseconds:20_000_000) }
                }
                let url=root.appendingPathComponent(name)
                try await emit(.init(id:name,name:name,path:url.path,size:UInt64(text.utf8.count),localPath:url.path))
            }
        }
        scan.resolveExternalSource={ [self] id,_,_ in root.appendingPathComponent(id) }
        coordinator.present(source:.local)
    }
    @objc func openScan() { coordinator.present(source:.local) }
    @objc func continueDiscovery() { finishDiscovery = true }
    func applicationWillTerminate(_ notification:Notification) { coordinator.close(preservingScans:true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
}
