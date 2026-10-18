import AppKit
import Foundation
import SwiftUI

private struct GeneratedSimilarityScopeHost: View {
    @ObservedObject var across: SimilarityAcrossDrives
    var body: some View {
        SimilarityAcrossDriveScopeView(across: across)
            .padding(20).frame(width: 900, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// In-process rendering of a generated scope panel. This never queries another
/// app, reads a user account, inspects a live window, or lists a user directory.
@main @MainActor struct SimilarityAcrossDriveScopeUITests {
    private static func accessibilityValue(_ node: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    private static func accessibilityNodes(in hosting: NSView) -> [NSObject] {
        var result: [NSObject] = [], pending: [NSObject] = [hosting]
        var seen = Set<ObjectIdentifier>()
        while let node = pending.popLast(), result.count < 4_096 {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            if let children = accessibilityValue(node, "accessibilityChildren") as? [Any] {
                pending.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
            if let view = node as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }

    private static func label(_ node: NSObject) -> String {
        accessibilityValue(node, "accessibilityLabel") as? String
            ?? accessibilityValue(node, "accessibilityValue") as? String ?? ""
    }

    private static func button(_ title: String, in hosting: NSView) -> NSObject? {
        accessibilityNodes(in: hosting).first {
            label($0) == title && accessibilityValue($0, "accessibilityRole") as? String == "AXButton"
        }
    }

    private static func press(_ node: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.method(for: selector), to: Action.self)
        return action(node, selector)
    }

    private static func enabled(_ node: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(node.method(for: selector), to: Getter.self)
        return getter(node, selector)
    }

    private static func startButton(in hosting: NSView) -> NSObject? {
        accessibilityNodes(in: hosting).first {
            accessibilityValue($0, "accessibilityIdentifier") as? String == "similarity-start-scan"
                && accessibilityValue($0, "accessibilityRole") as? String == "AXButton"
        }
    }

    private static func startEnabled(in hosting: NSView) -> Bool? {
        startButton(in: hosting).flatMap(enabled)
    }

    private static func identified(_ identifier: String, in hosting: NSView) -> NSObject? {
        accessibilityNodes(in: hosting).first {
            accessibilityValue($0, "accessibilityIdentifier") as? String == identifier
        }
    }

    private static func frame(_ node: NSObject) -> CGRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard node.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGRect
        let getter = unsafeBitCast(node.method(for: selector), to: Getter.self)
        return getter(node, selector)
    }

    private static func startVisible(in hosting: NSView) -> Bool {
        guard let window = hosting.window, let button = startButton(in: hosting), let rect = frame(button),
              rect.width > 0, rect.height > 0 else { return false }
        let viewport = window.convertToScreen(hosting.convert(hosting.bounds, to: nil)).insetBy(dx: -1, dy: -1)
        return viewport.contains(rect)
    }

    private static func scopeHeight(in hosting: NSView) -> CGFloat {
        // The wrapper contributes exactly 20pt padding above and below. Its
        // fitting size measures the production card's natural height instead
        // of the arbitrary offscreen window viewport height.
        max(0, hosting.fittingSize.height - 40)
    }

    private static func bitmap(_ hosting: NSView, to output: String) throws {
        precondition(["/private/tmp/mycloud-similarity-scope296.png",
                      "/private/tmp/mycloud-similarity-scope296-empty.png",
                      "/private/tmp/mycloud-similarity-scope296-minimum.png",
                      "/private/tmp/mycloud-similarity-scope296-many.png"].contains(output),
                     "The optional fixture bitmap must use a task-owned destination")
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            preconditionFailure("Generated scope view must support offscreen bitmap rendering")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("Generated scope view must render a PNG")
        }
        try image.write(to: URL(fileURLWithPath: output), options: .atomic)
        precondition(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && image.count > 1_024)
    }

    private static func until(_ condition: () -> Bool, hosting: NSView, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !condition() {
            let nodes = accessibilityNodes(in: hosting)
            let buttons = nodes.filter { accessibilityValue($0, "accessibilityRole") as? String == "AXButton" }
            // Counts concern only this generated NSHostingView. Do not dump
            // any app-wide accessibility tree or window names for diagnostics.
            print("Generated scope UI timeout: call_line=\(line) nodes=\(nodes.count) buttons=\(buttons.count) start_found=\(startButton(in: hosting) != nil) start_enabled=\(String(describing: startEnabled(in: hosting)))")
        }
        precondition(condition(), "Generated scope UI did not reach its expected state at call line \(line)")
    }

    static func main() async throws {
        _ = NSApplication.shared
        setbuf(stdout, nil)
        // SwiftUI lazily omits accessibility nodes until this process has an
        // accessibility client. Enable its own generated in-process tree; this
        // does not request trust or attach to the running user application.
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let priorEnhancedUI = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(priorEnhancedUI, forAttribute: enhancedUI) }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("MyCloudSimilarityScopeUI-\(UUID().uuidString)", isDirectory: true)
        let diskFolder = directory.appendingPathComponent("Generated Disk Folder", isDirectory: true)
        try fm.createDirectory(at: diskFolder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let suite = "com.wky.MyCloudDriver.SimilarityScopeUI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: directory)
        }
        let account = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let hub = CloudDriveHub(pikpak: account, defaults: defaults, restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
            localRootURL: directory)
        defer { hub.close(); account.stopForWindowClose() }
        let across = hub.similarityAcrossDrives
        let host = account.fileSimilarity
        // selectDrive discovers recovery sessions. Redirect every path it can
        // consult into this fixture before opening the production screen.
        for (index, coordinator) in ([host, across.coordinator] + hub.nativeDrives.map(\.similarity)).enumerated() {
            let configuration = SimilarityConfiguration(
                executable: directory.appendingPathComponent("unused-generated-engine"),
                models: directory.appendingPathComponent("unused-generated-models"),
                worker: directory.appendingPathComponent("unused-generated-worker"),
                dataDirectory: directory.appendingPathComponent("generated-cache-\(index)"),
                temporaryDirectory: directory.appendingPathComponent("generated-temp-\(index)"), environment: [:])
            coordinator.configuration = { _ in configuration }
        }
        host.selectDrive(SimilarityAcrossDrives.driveID)
        precondition(host.activeCoordinator === across.coordinator && across.scopes.isEmpty)
        let fullHosting = NSHostingView(rootView: FileSimilarityView(coordinator: host).defaultAppStorage(defaults))
        let fullWindow = NSWindow(contentRect: .init(x: -3_000, y: -3_000, width: 940, height: 740),
            styleMask: [.borderless], backing: .buffered, defer: false)
        fullWindow.isReleasedWhenClosed = false
        fullWindow.title = "Generated Similarity Start Fixture"
        fullWindow.appearance = NSAppearance(named: .aqua)
        fullWindow.contentView = fullHosting
        defer { fullWindow.close() }
        let hosting = NSHostingView(rootView: GeneratedSimilarityScopeHost(across: across)
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: .init(x: -3_000, y: -3_000, width: 940, height: 260),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Generated Similarity Scope Fixture"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        defer { window.close() }

        let imageArgument = CommandLine.arguments.first { $0.hasPrefix("--scope-ui-image=") }
        let imageOutput = imageArgument.map { String($0.dropFirst("--scope-ui-image=".count)) }
        if let imageOutput {
            precondition(imageOutput == "/private/tmp/mycloud-similarity-scope296.png")
        }
        try await until({ startEnabled(in: fullHosting) == false && startVisible(in: fullHosting) }, hosting: fullHosting)
        try await until({ scopeHeight(in: hosting) > 0 && identified("similarity-add-location", in: hosting) != nil }, hosting: hosting)
        let emptyHeight = scopeHeight(in: hosting)
        precondition(emptyHeight <= 100,
                     "The empty Locations card must remain compact rather than reserving rows for unselected providers")
        let addMenu = identified("similarity-add-location", in: hosting)!
        precondition(["AXButton", "AXMenuButton", "AXPopUpButton"].contains(
            accessibilityValue(addMenu, "accessibilityRole") as? String ?? ""),
                     "Locations must expose its single accessible Add menu")
        let emptyLabels = accessibilityNodes(in: hosting).map(label)
        precondition(emptyLabels.contains("Locations") && !emptyLabels.contains("Scan drive")
                     && !emptyLabels.contains("PikPak folders")
                     && !emptyLabels.contains("Folders on this Mac, network or external disks"),
                     "The empty card must contain one Locations header rather than separate unused provider sections")
        precondition(!accessibilityNodes(in: fullHosting).map(label).contains("Scan drive"),
                     "The production similarity header must not expose the old Scan drive picker")
        if imageOutput != nil { try bitmap(fullHosting, to: "/private/tmp/mycloud-similarity-scope296-empty.png") }

        let provider = ICloudDriveProvider(rootURL: diskFolder, kind: .local)
        across.addNativeScope(.init(drive: .local, providerRoot: provider.root, location: provider.root,
                                   selection: [], photosUsePreviews: false), provider: provider)
        try await until({ startEnabled(in: fullHosting) == true && startVisible(in: fullHosting) }, hosting: fullHosting)
        precondition(across.scopes.count == 1 && across.model.canStart,
                     "The production Start Scan button must enable immediately after adding one folder")
        let cloudRoot = SimilarityCloudRoot(id: "generated-cloud-scope-ui", name: "Generated Cloud Folder",
            path: "/Generated Cloud Folder", isFolder: true, size: 0, ancestors: [])
        across.addCloudScope([cloudRoot])
        precondition(across.scopes.count == 2 && across.model.canStart)
        let diskRemove = "Remove \(diskFolder.path)", cloudRemove = "Remove \(cloudRoot.path)"
        try await until({ scopeHeight(in: hosting) > emptyHeight
            && button(diskRemove, in: hosting) != nil && button(cloudRemove, in: hosting) != nil }, hosting: hosting)
        let populatedHeight = scopeHeight(in: hosting)
        precondition(populatedHeight <= 160,
                     "Two selected Locations must fit in a compact card")
        try await until({ startVisible(in: fullHosting) }, hosting: fullHosting)
        print("PASS generated compact Locations card exposes one Add menu and removable selected rows; empty_height=\(emptyHeight) two_row_height=\(populatedHeight)")
        if let imageOutput {
            try bitmap(hosting, to: imageOutput)
            try bitmap(fullHosting, to: "/private/tmp/mycloud-similarity-scope296-minimum.png")
            print("PASS generated compact scope and minimum-size screen render offscreen bitmaps without live window capture")
        }

        precondition(press(button(diskRemove, in: hosting)!))
        try await until({ across.scopes.count == 1 && button(diskRemove, in: hosting) == nil }, hosting: hosting)
        precondition(across.model.canStart && across.scopes[0].drive == .pikpak,
                     "Removing one source must preserve scan readiness for the remaining folder")
        try await until({ startEnabled(in: fullHosting) == true && startVisible(in: fullHosting) }, hosting: fullHosting)
        precondition(press(button(cloudRemove, in: hosting)!))
        try await until({ across.scopes.isEmpty && button(cloudRemove, in: hosting) == nil }, hosting: hosting)
        precondition(!across.model.canStart,
                     "Removing the last source through the rendered UI must disable Start Scan immediately")
        try await until({ startEnabled(in: fullHosting) == false && startVisible(in: fullHosting) }, hosting: fullHosting)
        precondition(!accessibilityNodes(in: fullHosting).map(label).contains("Scan drive"))
        print("PASS generated remove controls preserve one-location scan readiness and disable scanning when the final location is removed")
        print("PASS production Start Scan control stays visible at 940x740 and changes disabled to enabled with one folder and back after final removal, without a Scan drive picker")

        let manyRoots = (0..<24).map { index in
            SimilarityCloudRoot(id: "generated-many-scope-\(index)", name: "Generated Folder \(index)",
                path: "/Generated Folder \(index)", isFolder: true, size: 0, ancestors: [])
        }
        across.addCloudScope(manyRoots)
        try await until({ scopeHeight(in: hosting) > populatedHeight && identified("similarity-scope-list", in: hosting) != nil }, hosting: hosting)
        let manyHeight = scopeHeight(in: hosting)
        precondition(manyHeight <= 200,
                     "A long location list must scroll within a bounded card rather than grow the scan page")
        let scrollNodes = accessibilityNodes(in: hosting).filter {
            accessibilityValue($0, "accessibilityRole") as? String == "AXScrollArea"
        }
        precondition(!scrollNodes.isEmpty,
                     "A long selected-location list must expose its scrollable viewport")
        precondition(scrollNodes.contains { node in
            guard let viewport = frame(node) else { return false }
            return viewport.height > 0 && viewport.height <= 120
        }, "Selected locations must be limited to a small visible viewport")
        try await until({ startEnabled(in: fullHosting) == true && startVisible(in: fullHosting) }, hosting: fullHosting)
        if imageOutput != nil { try bitmap(fullHosting, to: "/private/tmp/mycloud-similarity-scope296-many.png") }
        print("PASS generated 24-folder location list scrolls within a bounded card; many_row_height=\(manyHeight), minimum-size Start Scan remains visible")
        for id in across.scopes.map(\.id) { across.removeScope(id) }
        try await until({ startEnabled(in: fullHosting) == false }, hosting: fullHosting)
    }
}
