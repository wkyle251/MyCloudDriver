import SwiftUI

/// Uses the real Browser and an isolated synthetic listing; no cloud access.
@main struct BrowserTreeRecoveryUITestApp: App {
    @StateObject private var model = DownloaderModel.folderRecoveryUIFixture()
    var body: some Scene {
        WindowGroup("Folder Recovery · Offline Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
        }.defaultSize(width: 1080, height: 760)
    }
}
