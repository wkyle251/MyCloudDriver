import Foundation
import AppKit
import SwiftUI

/// Hosts the real inline preview view. Model-only tests cannot see SwiftUI's
/// `.onChange` closure capturing the previous item, which left the model one
/// selection behind and the pane on "Preparing preview…" indefinitely.

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    func reset() { lock.lock(); ids = []; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

private final class SyntheticProvider: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    let requests = Requests()
    private let lock = NSLock()
    private var current: [CloudDriveItem] = []
    var items: [CloudDriveItem] {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    let delay: UInt64
    init(root: URL, delay: UInt64, kind: CloudDriveKind = .local) {
        self.root = .init(id: root.absoluteString, title: "Synthetic"); self.delay = delay; self.kind = kind
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        requests.record(item.id)
        try await Task.sleep(nanoseconds: delay)
        return item.url!
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: items, total: items.count) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

/// Mirrors NativeDriveInspector and NativeDriveWorkspace for the inline preview:
/// the workspace reacts to identity changes while the pane renders the preview.
private struct Harness: View {
    @ObservedObject var browser: NativeDriveModel
    let provider: SyntheticProvider
    var body: some View {
        Group {
            if let item = browser.inspectorItem, !item.isFolder, item.mediaType == "video" {
                NativeMediaPreview(item: item, provider: provider, model: browser.mediaPreview)
            } else { Text("none") }
        }.onChange(of: browser.inspectorPreviewIdentity) { _ in browser.selectionChanged() }
    }
}

@main @MainActor struct NativeMediaPreviewWiringTests {
    /// The pane shows the preview or its failure only for a model bound to the selected file.
    fileprivate static func settled(_ browser: NativeDriveModel, _ provider: SyntheticProvider, timeout: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = browser.inspectorItem, browser.mediaPreview.matches(item, provider: provider),
               browser.mediaPreview.ready || browser.mediaPreview.failure != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
    static func main() async throws {
        _ = NSApplication.shared
        let suite = "MyCloudDriver.NativeMediaWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func rows(_ revision: String) throws -> [CloudDriveItem] {
            try (0..<6).map { index in
                let url = directory.appendingPathComponent("generated-\(index).mp4")
                if !FileManager.default.fileExists(atPath: url.path) { try Data("generated media \(index)".utf8).write(to: url) }
                return CloudDriveItem(id: "row-\(index)", name: "generated-\(index).mp4", isFolder: false, bytes: 15,
                    modified: Date(timeIntervalSince1970: 1_700_000_000), url: url, mediaType: "video",
                    isDownloaded: revision.isEmpty, revision: "r\(index)\(revision)")
            }
        }

        let cases: [(CloudDriveKind, UInt64, ExternalVolume.Kind?)] = [(.local, 0, nil), (.local, 150, nil),
            (.local, 0, .externalDisk), (.local, 150, .networkShare), (.icloud, 150, nil), (.photos, 150, nil)]
        for (kind, delay, bufferedKind) in cases {
            let label = "\(kind.title), provider delay \(delay) ms, \(String(describing: bufferedKind))"
            let provider = SyntheticProvider(root: directory, delay: delay * 1_000_000, kind: kind)
            provider.items = try rows("-placeholder")
            let browser = NativeDriveModel(kind: kind, temporaryRoot: directory.appendingPathComponent("Staging-\(UUID())"),
                playbackSettings: .init(defaults: defaults))
            browser.mediaPreview.bufferedVolume = { _ in bufferedKind }
            defer { browser.close() }
            browser.connect(provider)
            for _ in 0..<200 where browser.isLoading || browser.visibleRows.count != 6 { try? await Task.sleep(nanoseconds: 20_000_000) }
            precondition(browser.visibleRows.count == 6, "Synthetic folder did not load")

            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0.01; window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: Harness(browser: browser, provider: provider))
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }

            browser.select(browser.visibleRows[2], extending: false, toggling: false)
            let firstSettled = await settled(browser, provider)
            precondition(firstSettled, "First selection never became displayable (\(label))")
            precondition((browser.mediaPreview.sourceBufferStatus != nil) == (kind != .local || bufferedKind != nil),
                "Only the internal local disk omits the buffering panel")

            // One selection change at a time: the file requested must be the one now selected.
            for (step, offset) in [1, 1, -1, -1].enumerated() {
                provider.requests.reset()
                browser.moveSelection(offset)
                let selected = browser.inspectorItem!.id
                let stepSettled = await settled(browser, provider)
                precondition(stepSettled, "Selection step \(step) left the preview bound to another file (\(label))")
                precondition(provider.requests.all.last == selected,
                    "Selection step \(step) loaded \(provider.requests.all) instead of \(selected) (\(label))")
            }

            // Arrow-key bursts: whatever the last selection is must finish bound to it.
            var generator = SystemRandomNumberGenerator()
            for round in 0..<6 {
                for _ in 0..<Int.random(in: 1...6, using: &generator) {
                    browser.moveSelection(Bool.random(using: &generator) ? 1 : -1)
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 0...40_000_000, using: &generator))
                }
                let burstSettled = await settled(browser, provider)
                precondition(burstSettled, "Selection burst \(round) never settled (\(label))")
            }

            // The selected file's identity changes while it loads, as an iCloud placeholder hydrates.
            for round in 0..<4 {
                browser.moveSelection(round % 2 == 0 ? 1 : -1)
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0...60_000_000, using: &generator))
                provider.items = try rows("-hydrated-\(round)")
                browser.reload()
                let changeSettled = await settled(browser, provider)
                precondition(changeSettled, "Identity change \(round) never settled (\(label))")
            }
            print("PASS inline preview binds to the selected file after every selection and identity change (\(label))")
        }
    }
}
