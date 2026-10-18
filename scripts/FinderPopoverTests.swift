// Standalone generated AppKit/SwiftUI lifecycle stress test. Compile with only
// macos/FinderPopover.swift; no account, provider, filesystem or app state.
import AppKit
import SwiftUI

private struct GeneratedPopoverMarker: EnvironmentKey { static let defaultValue = "missing" }
private extension EnvironmentValues {
    var generatedPopoverMarker: String {
        get { self[GeneratedPopoverMarker.self] }
        set { self[GeneratedPopoverMarker.self] = newValue }
    }
}
private final class GeneratedPopoverDependency: ObservableObject { let value = "generated dependency" }
@MainActor private final class GeneratedPopoverState: ObservableObject {
    @Published var isPresented = false
    @Published var showsAnchor = true
    @Published var rows = 0
    @Published var message = "Generated message"
    @Published var requestedSize = CGSize(width: 460, height: 360)
    var inheritedEnvironment = false
}
private struct GeneratedPopoverContent: View {
    @ObservedObject var state: GeneratedPopoverState
    @EnvironmentObject private var dependency: GeneratedPopoverDependency
    @Environment(\.generatedPopoverMarker) private var marker
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generated activity").font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    Text(state.message)
                    ForEach(0..<state.rows, id: \.self) { row in Text("Generated row \(row)") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Close generated popover") { state.isPresented = false }
        }.padding(16)
            .onAppear { state.inheritedEnvironment = marker == "generated marker" && dependency.value == "generated dependency" }
    }
}
private struct GeneratedPopoverRoot: View {
    @ObservedObject var state: GeneratedPopoverState
    var body: some View {
        VStack {
            Text("Generated popover lifecycle fixture")
            if state.showsAnchor {
                Button("Generated anchor") { state.isPresented.toggle() }
                    .finderPopover(isPresented: $state.isPresented, contentSize: state.requestedSize) {
                        GeneratedPopoverContent(state: state)
                    }
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@main @MainActor struct FinderPopoverTests {
    static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Generated popover fixture timed out at line \(line)")
    }
    static func findAnchor(_ view: NSView?) -> FinderPopoverAnchorView? {
        guard let view else { return nil }
        if let anchor = view as? FinderPopoverAnchorView { return anchor }
        for child in view.subviews { if let anchor = findAnchor(child) { return anchor } }
        return nil
    }
    static func main() {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS generated popover lifecycle suite"); exit(0) }
            catch { preconditionFailure("Generated popover fixture failed: \(error.localizedDescription)") }
        }
        application.run()
    }
    static func run() async throws {
        precondition(Thread.isMainThread, "The fixture must exercise the physical AppKit run loop")
        let state = GeneratedPopoverState(), dependency = GeneratedPopoverDependency()
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 800, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Generated popover fixture"
        window.contentView = NSHostingView(rootView: GeneratedPopoverRoot(state: state)
            .environmentObject(dependency).environment(\.generatedPopoverMarker, "generated marker"))
        window.makeKeyAndOrderFront(nil)
        try await until { findAnchor(window.contentView)?.controller != nil }
        let anchor = findAnchor(window.contentView)!, controller = anchor.controller!
        precondition(anchor.bounds.width > 0 && anchor.bounds.height > 0 && anchor.hitTest(.zero) == nil)
        state.isPresented = true
        try await until { controller.popover?.isShown == true && state.inheritedEnvironment }
        let initialSize = controller.presentationSize!, firstPopover = controller.popover!
        precondition(!firstPopover.animates && firstPopover.behavior == .transient && firstPopover.contentSize == initialSize)
        precondition((firstPopover.contentViewController as? NSHostingController<AnyView>)?.sizingOptions.isEmpty == true)
        var maximumGap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        for index in 0..<300 {
            state.rows = index % 2 == 0 ? 0 : 50
            state.message = String(repeating: "Generated activity text. ", count: index % 2 == 0 ? 1 : 40)
            state.requestedSize = .init(width: index % 2 == 0 ? 400 : 560, height: index % 2 == 0 ? 260 : 540)
            if index % 15 == 0 { window.setContentSize(.init(width: index % 30 == 0 ? 820 : 940, height: 620)) }
            try await Task.sleep(nanoseconds: 3_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            maximumGap = max(maximumGap, now - previous); previous = now
            precondition(controller.presentationSize == initialSize && controller.popover?.contentSize == initialSize,
                "Live content and requested-size changes must not resize the current presentation")
        }
        print("PASS generated dynamic rows/messages and owner resize preserve the pinned viewport; max heartbeat gap ms=\(maximumGap * 1000)")
        FinderPopover.dismissAll()
        try await until { !state.isPresented && controller.popover == nil }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: Text("Generated sheet").padding())
        window.beginSheet(sheet, completionHandler: { _ in })
        state.isPresented = true
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(controller.popover == nil && state.isPresented, "A pending popover must not present beneath a sheet")
        window.endSheet(sheet); sheet.orderOut(nil)
        try await until { controller.popover?.isShown == true }
        FinderPopover.dismissAll()
        try await until { !state.isPresented && controller.popover == nil }
        print("PASS requested presentation waits for attached sheet dismissal without polling")
        for _ in 0..<30 {
            state.isPresented = true
            try await until { controller.popover?.isShown == true }
            precondition(controller.presentationSize == state.requestedSize, "The next presentation uses the latest requested viewport")
            controller.popover?.performClose(nil)
            // An old close callback must not cancel the next presentation.
            try await until { !state.isPresented && controller.popover == nil }
        }
        state.isPresented = true
        try await until { controller.popover?.isShown == true }
        controller.popoverDidClose(.init(name: NSPopover.didCloseNotification, object: firstPopover))
        precondition(controller.popover?.isShown == true && state.isPresented)
        state.showsAnchor = false
        try await until { !state.isPresented && controller.popover == nil }
        print("PASS repeated native dismissal, stale callbacks and anchor removal close cleanly")
        state.showsAnchor = true
        try await until { findAnchor(window.contentView)?.controller != nil }
        let nextController = findAnchor(window.contentView)!.controller!
        state.isPresented = true
        try await until { nextController.popover?.isShown == true }
        window.close()
        try await until { !state.isPresented && nextController.popover == nil }
        print("PASS owner-window close dismisses its popover and resets presentation")

        var detachedPresented = true
        let detached = FinderPopoverAnchorView(), pending = FinderPopoverController()
        detached.controller = pending
        pending.update(anchor: detached, isPresented: .init(get: { detachedPresented }, set: { detachedPresented = $0 }),
            contentSize: .init(width: CGFloat.nan, height: CGFloat.infinity), arrowEdge: .top, content: AnyView(Text("Generated pending content")))
        pending.invalidate()
        try await until { !detachedPresented }
        precondition(pending.popover == nil, "A queued presentation cannot outlive a detached anchor")
        print("PASS pending detached presentation cannot reopen after invalidation")

        let replacementWindow = NSWindow(contentRect: .init(x: 150, y: 150, width: 700, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        replacementWindow.isReleasedWhenClosed = false
        replacementWindow.title = "Generated replacement fixture"
        let oldAnchor = FinderPopoverAnchorView(frame: .init(x: 30, y: 30, width: 120, height: 26))
        let newAnchor = FinderPopoverAnchorView(frame: .init(x: 30, y: 80, width: 120, height: 26))
        let container = NSView(frame: .init(x: 0, y: 0, width: 700, height: 520))
        container.addSubview(oldAnchor); container.addSubview(newAnchor)
        replacementWindow.contentView = container; replacementWindow.makeKeyAndOrderFront(nil)
        let oldOwner = FinderPopoverController(), newOwner = FinderPopoverController(), sharedID = UUID()
        oldAnchor.controller = oldOwner; newAnchor.controller = newOwner
        var sharedPresented = true
        let sharedBinding = Binding(get: { sharedPresented }, set: { sharedPresented = $0 })
        oldOwner.update(anchor: oldAnchor, isPresented: sharedBinding, contentSize: .init(width: 320, height: 220),
            presentationID: sharedID, arrowEdge: .top, content: AnyView(Text("Generated old owner")))
        try await until { oldOwner.popover?.isShown == true }
        // Both calls happen before the next main turn. Old teardown's queued
        // binding reset must lose ownership to this replacement presentation.
        oldOwner.invalidate()
        newOwner.update(anchor: newAnchor, isPresented: sharedBinding, contentSize: .init(width: 320, height: 220),
            presentationID: sharedID, arrowEdge: .top, content: AnyView(Text("Generated new owner")))
        try await until { newOwner.popover?.isShown == true }
        precondition(sharedPresented && oldOwner.popover == nil)
        newOwner.dismiss()
        try await until { !sharedPresented && newOwner.popover == nil }
        // This plain binding has no SwiftUI false update at all: consuming the
        // owned reset must be enough to allow the immediate fresh request.
        sharedPresented = true
        newOwner.update(anchor: newAnchor, isPresented: sharedBinding, contentSize: .init(width: 320, height: 220),
            presentationID: sharedID, arrowEdge: .top, content: AnyView(Text("Generated immediate reopen")))
        try await until { newOwner.popover?.isShown == true }
        newOwner.invalidate()
        try await until { !sharedPresented }
        replacementWindow.close()
        print("PASS old anchor teardown cannot clear a replacement; immediate reopen consumes its owned reset")
    }
}
