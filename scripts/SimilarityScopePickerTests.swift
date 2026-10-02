import AppKit
import Foundation

@main struct SimilarityScopePickerTests {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Folder picker did not settle")
    }
    @MainActor static func main() async throws {
        let root = CloudDriveLocation(id: "", title: "PikPak")
        let album = CloudDriveLocation(id: "album", title: "Album")
        let nested = CloudDriveLocation(id: "nested", title: "Nested")
        var accepted: [CloudDriveLocation] = []
        var requests: [(String, String?)] = []
        let picker = SimilarityScopePicker(title: "Choose PikPak Folder", root: root, load: { location, token in
            requests.append((location.id, token))
            if location.id == "album" { return .init(folders: [nested]) }
            if token == "next" { return .init(folders: [album, .init(id: "z", title: "Other")]) }
            return .init(folders: [album], nextPage: "next")
        }, accept: { accepted = $0 })
        picker.reload(); try await wait { !picker.isLoading }
        precondition(picker.folders.count == 1 && picker.nextPage == "next")
        picker.reload(more: true); try await wait { !picker.isLoading }
        precondition(picker.folders.count == 2 && picker.nextPage == nil && requests.last?.1 == "next")
        picker.enter(album); try await wait { !picker.isLoading }
        picker.selection = nested.id; picker.choose()
        precondition(accepted.map(\.id) == ["", "album", "nested"] && picker.path == "/Album")
        picker.back(); try await wait { !picker.isLoading }
        precondition(picker.path == "/" && picker.selection == nil)
        picker.choose(); precondition(accepted.map(\.id) == [""])
        print("PASS direct folder selection, pagination, duplicate IDs, parent navigation and complete ancestor routes")

        var allowed = false
        let stale = SimilarityScopePicker(title: "Race", root: root, load: { location, _ in
            if location.id == "" { try? await Task.sleep(nanoseconds: 100_000_000); return .init(folders: [album]) }
            return .init(folders: [nested])
        }, accept: { _ in allowed = true })
        stale.reload(); stale.choose(); precondition(!allowed)
        stale.enter(album); try await wait { !stale.isLoading }
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(stale.folders.map(\.id) == ["nested"])
        stale.reload(); stale.close(); try await Task.sleep(nanoseconds: 30_000_000)
        precondition(!stale.isLoading)
        let failure = SimilarityScopePicker(title: "Denied", root: root, load: { _, _ in throw CloudDriveError.message("Account access expired") }, accept: { _ in allowed = true })
        failure.reload(); try await wait { !failure.isLoading }; failure.choose()
        precondition(failure.error == "Account access expired" && !allowed)
        print("PASS loading/error protection, stale response cancellation and close during directory loading")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SimilarityScopeTest-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Album/Nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let native = NativeDriveModel(kind: .icloud)
        native.connect(ICloudDriveProvider(rootURL: folder))
        try await wait { !native.isLoading }
        let browser = native.location
        native.similarity.chooseFolderScope?()
        let nativePicker = native.similarity.scopePicker!
        nativePicker.reload(); try await wait { !nativePicker.isLoading }
        precondition(nativePicker.folders.map(\.title) == ["Album"])
        nativePicker.selection = nativePicker.folders[0].id; nativePicker.choose()
        precondition(native.similarity.local.externalScopeNames.first?.hasSuffix("Album") == true)
        precondition(native.location == browser, "Choosing a scan location must not navigate Browser")
        native.close()
        print("PASS iCloud folder picker selects an independent scan scope using the connected provider")
    }
}
