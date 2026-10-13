import AppKit
import Foundation

@main
struct FinderFileOpeningTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PikPak-Open-Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(BrowserPage.self, from: Data(#"{"files":[],"account_id":"one","account_profile":{"sub":"one","name":"  Taylor Chen  "}}"#.utf8))
        precondition(page.accountProfile?.displayName == "Taylor Chen")
        let oldPage = try decoder.decode(BrowserPage.self, from: Data(#"{"files":[]}"#.utf8))
        precondition(oldPage.accountProfile == nil)
        for json in [#"{"sub":"one"}"#, #"{"sub":"one","name":null}"#, #"{"sub":"one","name":" \n "}"#] {
            let profile = try decoder.decode(PikPakAccountProfile.self, from: Data(json.utf8))
            precondition(profile.displayName == nil)
        }
        print("PASS profile: server name, whitespace/null fallback, legacy browser response")

        precondition(FinderFileOpenStorage.safeFilename("../../Report.txt") == "Report.txt")
        precondition(FinderFileOpenStorage.safeFilename("C:\\folder\\Report.txt") == "Report.txt")
        for name in ["", "/", ".", "..", "\u{0}"] {
            precondition(FinderFileOpenStorage.safeFilename(name) == "PikPak File")
        }
        let source = URL(string: "https://fixture.invalid/Readme.txt")!
        func info(_ content: String = source.absoluteString, size: UInt64 = 5) -> PreviewInfo {
            PreviewInfo(name: "Readme.txt", size: size, mimeType: "text/plain", thumbnailLink: nil,
                        iconLink: nil, contentLink: content, sources: nil)
        }
        precondition(FinderFileOpenStorage.originalURL(info()) == source)
        precondition(FinderFileOpenStorage.originalURL(info("https://fixture.invalid/stream.m3u8")) == nil)
        precondition(FinderFileOpenStorage.originalURL(info("http://fixture.invalid/file.txt")) == nil)
        let transcode = PreviewSource(url: "https://fixture.invalid/transcode.mp4", label: "720P", isOrigin: false,
                                      videoCodec: "h264", audioCodec: nil)
        let original = PreviewSource(url: source.absoluteString, label: "Original", isOrigin: true,
                                     videoCodec: nil, audioCodec: nil)
        let media = PreviewInfo(name: "Video.mov", size: 5, mimeType: "video/quicktime", thumbnailLink: nil,
                                iconLink: nil, contentLink: transcode.url, sources: [transcode, original])
        precondition(FinderFileOpenStorage.originalURL(media) == source, "ignore preferred playback transcode")
        let transcodeOnly = PreviewInfo(name: media.name, size: 5, mimeType: media.mimeType, thumbnailLink: nil,
                                       iconLink: nil, contentLink: transcode.url, sources: [transcode])
        precondition(FinderFileOpenStorage.originalURL(transcodeOnly) == nil)
        print("PASS file sources: safe names, original HTTPS content, reject HLS and insecure sources")

        let configuration = FinderFileOpenConfiguration(executable: URL(fileURLWithPath: "/usr/bin/false"),
            environment: [:], arguments: [], exchangeDirectory: directory, copiesDirectory: directory, proxyURL: "fixture-proxy")
        let opener = FinderFileOpener()
        var downloads = 0
        var launched: [(URL, URL?)] = []
        var failed = false
        opener.onStatus = { _, error in if error { failed = true } }
        opener.resolve = { _ in info() }
        opener.download = { url, proxy in
            precondition(url == source && proxy == "fixture-proxy")
            downloads += 1
            let file = directory.appendingPathComponent("download-\(UUID().uuidString).part")
            try Data("hello".utf8).write(to: file)
            return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        opener.launch = { file, application in
            let data = try Data(contentsOf: file)
            precondition(data == Data("hello".utf8))
            precondition(file.lastPathComponent == "Readme.txt")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let parent = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
            precondition((parent[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            launched.append((file, application))
        }
        func finish() async throws {
            for _ in 0..<300 {
                if opener.activeNames.isEmpty { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("file opening timed out")
        }
        opener.open(identity: "account-one|file", name: "Readme.txt", application: nil, configuration: configuration)
        opener.open(identity: "account-one|file", name: "Readme.txt", application: nil, configuration: configuration)
        try await finish()
        precondition(downloads == 1 && launched.count == 1 && launched[0].1 == nil && !failed)
        let application = URL(fileURLWithPath: "/Applications/Fixture.app")
        opener.open(identity: "account-one|file", name: "Readme.txt", application: application, configuration: configuration)
        try await finish()
        precondition(downloads == 1 && launched.count == 2 && launched[1].1 == application)
        precondition(launched[0].0 == launched[1].0, "reopening preserves local edits")
        opener.open(identity: "link-two|file", name: "Readme.txt", application: nil, configuration: configuration)
        try await finish()
        precondition(downloads == 2 && launched[2].0 != launched[0].0, "separate source copies")
        opener.reset()
        precondition(FileManager.default.fileExists(atPath: launched[0].0.path), "keep external documents after account reset")
        print("PASS handoff: complete private copy, default/chosen app, repeat-open reuse, source isolation, persistent opened copies")

        opener.resolve = { _ in info(size: 6) }
        opener.open(identity: "partial", name: "Readme.txt", application: nil, configuration: configuration)
        try await finish()
        precondition(failed && launched.count == 3, "partial download must never launch")
        failed = false
        opener.resolve = { _ in info() }
        opener.download = { url, _ in
            let file = directory.appendingPathComponent("server-error.part")
            try Data("error".utf8).write(to: file)
            return (file, HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        // A refused signed link expires on its own, so the opener fetches a fresh one and retries with a visible
        // status instead of reporting a failure; the refused body must never reach an app and is removed at once.
        var retryStatus: String?
        opener.onStatus = { message, error in
            precondition(Thread.isMainThread, "A retry must not publish UI updates from the background executor")
            MainActor.preconditionIsolated()
            if error { failed = true }
            else if message.hasPrefix("Retrying the download to open Readme.txt in ") { retryStatus = message }
        }
        opener.open(identity: "denied", name: "Readme.txt", application: nil, configuration: configuration)
        for _ in 0..<300 where retryStatus == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(retryStatus != nil, "an HTTP error is retried automatically and says so")
        precondition(!failed && launched.count == 3 && opener.activeNames["denied"] == "Readme.txt")
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("server-error.part").path))
        opener.cancelAll()
        precondition(opener.activeNames.isEmpty, "cancelling stops the waiting retry")
        print("PASS failures: incomplete files fail at once, HTTP-error files are retried visibly; neither reaches external apps and temporary data is removed")

        failed = false
        var resume: CheckedContinuation<PreviewInfo, Never>?
        opener.resolve = { _ in await withCheckedContinuation { resume = $0 } }
        opener.open(identity: "cancelled", name: "Readme.txt", application: nil, configuration: configuration)
        while resume == nil { await Task.yield() }
        opener.reset()
        resume?.resume(returning: info())
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(opener.activeNames.isEmpty && launched.count == 3 && !failed)
        print("PASS cancellation: stale metadata after cancel/account reset cannot download or open a file")

        opener.resolve = { _ in info() }
        opener.download = { url, _ in
            let file = directory.appendingPathComponent("range-\(UUID().uuidString).part")
            try Data("hello".utf8).write(to: file)
            return (file, HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-4/5"])!)
        }
        opener.launch = { file, _ in
            precondition(try! Data(contentsOf: file) == Data("hello".utf8))
            launched.append((file, nil))
        }
        opener.open(identity: "whole-range", name: "Readme.txt", application: application, configuration: configuration)
        try await finish()
        precondition(launched.count == 4 && !failed, "A verified whole-object 206 must reach the chosen app")
        opener.download = { url, _ in
            let file = directory.appendingPathComponent("short-range.part")
            try Data("he".utf8).write(to: file)
            return (file, HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes 0-1/5"])!)
        }
        opener.open(identity: "short-range", name: "Readme.txt", application: application, configuration: configuration)
        try await finish()
        precondition(failed && launched.count == 4, "An incomplete 206 must fail visibly without endless Opening or launch")
        print("PASS Open With range responses: whole-object HTTP 206 opens, truncated ranges fail and never reach IINA")

        #if FINDER_WORKSPACE_TESTS
        let suite = "PikPak-Open-Model-Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testQuickLookRequests(defaults: defaults)
        try await DownloaderModel.testQuickLookNavigation(defaults: defaults, directory: directory)
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false,
                 browser: Bool = true, panel: Bool = false, sheet: Bool = false, editing: Bool = false) -> FinderQuickLookKeyAction? {
            FinderQuickLookKeyboard.action(keyCode: code, modifiers: modifiers, isRepeat: repeatKey,
                isFileWindow: browser, isOwnedPreviewPanel: panel, hasSheet: sheet, isTextInput: editing)
        }
        precondition(key(49) == .toggle && key(53) == .cancel)
        precondition(key(49, modifiers: [.capsLock, .function]) == .toggle)
        precondition(key(49, repeatKey: true) == .consumeRepeat, "holding Space cannot toggle the panel repeatedly")
        precondition(key(49, editing: true) == nil && key(53, sheet: true) == nil)
        precondition(key(49, browser: false) == nil, "Settings and other windows keep their own Space behavior")
        precondition(key(49, browser: false, panel: true) == .toggle)
        precondition(key(49, modifiers: .command) == nil && key(49, modifiers: .shift) == nil)
        precondition(key(125, browser: false, panel: true) == .next && key(126, browser: false, panel: true) == .previous)
        precondition(key(125, repeatKey: true, browser: false, panel: true) == .next, "holding an arrow keeps moving through files")
        precondition(key(125) == nil && key(126, browser: false) == nil, "browser and other windows retain their own arrow handling")
        precondition(key(125, browser: false, panel: true, editing: true) == nil && key(125, browser: false, panel: true, sheet: true) == nil)
        print("PASS Quick Look keys: Space/Escape, repeat, Caps Lock/Fn, typing, sheets, other windows and owned panel")
        let model = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let file = model.browserItems.first { !$0.isFolder }!
        let folder = model.browserItems.first { $0.isFolder }!
        precondition(model.canOpenBrowserFile(file) && !model.canOpenBrowserFile(folder))
        let applications = FinderFileApplications.applications(for: file)
        let again = FinderFileApplications.applications(for: file)
        precondition(Set(applications.map(\.id)).count == applications.count)
        precondition(applications.allSatisfy { !$0.icon.isTemplate && $0.icon.size == NSSize(width: 16, height: 16) })
        precondition(applications.filter(\.isDefault).count <= 1)
        if applications.contains(where: \.isDefault) { precondition(applications.first?.isDefault == true) }
        precondition(zip(applications, again).allSatisfy { $0.id == $1.id && $0.icon === $1.icon }, "cache icons instead of loading them per row")
        print("PASS Open With: canonical app identities, default first, full-color 16-point icons and cache reuse")
        var opened = 0
        model.fileOpener.launch = { _, _ in opened += 1 }
        model.openBrowserFile(file)
        model.selectBrowserItem(folder)
        for _ in 0..<300 where opened == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(opened == 1 && model.selectedBrowserItemID == folder.id, "opening outlives selection changes")
        model.stopForWindowClose()
        print("PASS model: right-click target captured independently of current selection; folders excluded")
        #endif
    }
}
