import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var sessions: WorkspaceSessionManager?
    weak var transfers: DownloaderModel?
    weak var fileSearch: FileSearchModel?
    weak var drives: CloudDriveHub?
    private var terminationInProgress = false
    private var handledSimilarityLaunch = false

    func resumeRequestedSimilarity(in hub: CloudDriveHub) {
        guard !handledSimilarityLaunch else { return }
        handledSimilarityLaunch = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let option = arguments.firstIndex(of: "--resume-similarity-session"),
              arguments.indices.contains(option + 1),
              let id = UUID(uuidString: arguments[option + 1])?.uuidString else { return }
        // Use the same account, provider reconnection and window-owned model
        // as Resume. Only the explicitly named Across Drives scan is eligible.
        let coordinator = hub.similarityAcrossDrives.coordinator
        coordinator.refreshRecovery()
        guard let saved = coordinator.local.recoverableSessions.first(where: {
            $0.id == id && $0.acrossDriveScopes?.isEmpty == false
        }) else {
            NSLog("The requested similarity scan is unavailable for this account.")
            return
        }
        coordinator.resume(coordinator.local, session: saved)
        hub.presentAcrossDriveSimilarity()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        Task { @MainActor in
            let saved: Bool
            if let sessions { saved = await sessions.prepareDownloadsForApplicationTermination() }
            else if let transfers { saved = await transfers.prepareDownloadsForApplicationTermination() }
            else { saved = true }
            terminationInProgress = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalTorrentModel.shared.shutdown()
        if let sessions { sessions.closeAll(); return }
        transfers?.stopForWindowClose()
        fileSearch?.close()
        drives?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PikPakDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessions = WorkspaceSessionManager()
    private var hub: CloudDriveHub { sessions.activeHub }
    private var model: DownloaderModel { hub.pikpak }

    var body: some Scene {
        Window("MyCloudDriver", id: "main") {
            WorkspaceSessionRoot(hub: sessions.initialHub, manager: sessions)
                .onAppear {
                    appDelegate.sessions = sessions
                    appDelegate.transfers = model
                    appDelegate.fileSearch = model.fileSearch
                    appDelegate.drives = hub
                    // The Home screen does not browse PikPak. Verify the saved
                    // account here too, so its unpaused durable queue resumes
                    // without requiring the user to open that drive first.
                    model.refreshQuota()
                    appDelegate.resumeRequestedSimilarity(in: hub)
                }
        }
        .defaultSize(width: 1240, height: 900)
        .commands {
            FinderCommands(settings: sessions.settings, sessions: sessions)
            FinderSearchCommands(sessions: sessions)
        }

        Settings {
            FinderSettingsView(settings: model.finderSettings, model: model, hub: hub)
        }
    }
}
