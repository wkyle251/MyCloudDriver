import AppKit
import SwiftUI

// test-window-minimum-size.sh prepends the actual private controller source,
// with observation-only counters. No account, file or user window is inspected.
@MainActor private enum MinimumSizeProbe {
    static var callbackDepth = 0
    static var enforcing = false
    static var ownedWrites = 0
    static var writesInsideCallbacks = 0
    static var scheduledTurns = 0
    static var writesByWindow: [ObjectIdentifier: Int] = [:]
    static func geometry(_ window: NSWindow, _ operation: () -> Void) {
        if enforcing {
            ownedWrites += 1
            writesByWindow[ObjectIdentifier(window), default: 0] += 1
            if callbackDepth > 0 { writesInsideCallbacks += 1 }
        }
        operation()
    }
}

private final class GeneratedMinimumWindow: NSWindow {
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { MinimumSizeProbe.geometry(self) { super.contentMinSize = newValue } }
    }
    override var minSize: NSSize {
        get { super.minSize }
        set { MinimumSizeProbe.geometry(self) { super.minSize = newValue } }
    }
}

@MainActor private final class GeneratedMinimumModel: ObservableObject {
    @Published var phase = false
    @Published var popover = false
    @Published var relaxed = false
}

private struct GeneratedMinimumContent: View {
    @ObservedObject var model: GeneratedMinimumModel
    var body: some View {
        VStack {
            Text("Generated window sizing test")
            Button("Generated status") { model.popover.toggle() }
                .popover(isPresented: $model.popover) {
                    Text(model.phase ? "Generated progress" : "Generated status ready")
                        .frame(width: model.phase ? 400 : 460, height: model.phase ? 180 : 240)
                }
        }
        .frame(minWidth: model.relaxed ? 0 : (model.phase ? 540 : 620),
               minHeight: model.relaxed ? 0 : (model.phase ? 360 : 420))
        .background(WindowMinimumSizeController().frame(width: 0, height: 0))
    }
}

@main @MainActor private struct WindowMinimumSizeTests {
    static func controller(in view: NSView) -> WindowMinimumSizeControllerView? {
        if let value = view as? WindowMinimumSizeControllerView { return value }
        return view.subviews.lazy.compactMap { controller(in: $0) }.first
    }
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = GeneratedMinimumModel()
        let window = GeneratedMinimumWindow(contentRect: .init(x: 80, y: 80, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Generated minimum-size test"; window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: GeneratedMinimumContent(model: model))
        hosting.sizingOptions = [.minSize]
        window.contentView = hosting; window.orderFront(nil)
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { timer in
            MainActor.assumeIsolated {
                ticks += 1; model.phase.toggle()
                if ticks % 8 == 0 { model.popover.toggle() }
                hosting.layoutSubtreeIfNeeded(); app.updateWindows()
                guard ticks == 80 else { return }
                timer.invalidate(); model.popover = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    precondition(MinimumSizeProbe.ownedWrites > 0)
                    precondition(MinimumSizeProbe.writesInsideCallbacks == 0,
                        "Window minimum changes must run after layout/update callbacks")
                    precondition(window.contentMinSize == .zero)
                    precondition(window.minSize == window.frameRect(forContentRect: .zero).size)
                    // The stress phase deliberately imposes a hard minimum,
                    // which both old and new controllers can have reapplied by
                    // NSHostingView while resizing. Restore flexible content,
                    // as the main workspace uses, before testing user shrinking.
                    model.relaxed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        window.setContentSize(.init(width: 300, height: 200))
                        for _ in 0..<10 { app.updateWindows() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            let scheduled = MinimumSizeProbe.scheduledTurns
                            for _ in 0..<10 { app.updateWindows() }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                precondition(window.contentRect(forFrameRect: window.frame).size == .init(width: 300, height: 200),
                                    "SwiftUI sizing updates must preserve the ability to shrink the window")
                                precondition(MinimumSizeProbe.scheduledTurns == scheduled,
                                    "Stable didUpdate notifications must not create a self-scheduling reset loop")
                                print("PASS dynamic SwiftUI/popover sizing defers minimum changes and preserves shrinking without reset loops")
                                checkAnchorAndClose(window: window, hosting: hosting)
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { preconditionFailure("Generated sizing test timed out") }
        app.run()
    }
    static func checkAnchorAndClose(window: GeneratedMinimumWindow, hosting: NSView) {
        guard let bridge = controller(in: hosting) else { preconditionFailure("Generated controller was not attached") }
        window.contentMinSize = .init(width: 450, height: 350)
        bridge.scheduleMinimumSizeReset()
        window.contentView = nil
        let replacement = GeneratedMinimumWindow(contentRect: .init(x: 100, y: 100, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        replacement.isReleasedWhenClosed = false
        replacement.contentView = hosting; replacement.orderFront(nil)
        replacement.contentMinSize = .init(width: 500, height: 400)
        bridge.scheduleMinimumSizeReset()
        let previousWrites = MinimumSizeProbe.writesByWindow[ObjectIdentifier(window), default: 0]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            precondition(MinimumSizeProbe.writesByWindow[ObjectIdentifier(window), default: 0] == previousWrites,
                "An old queued reset must not write a replaced anchor window")
            precondition(replacement.contentMinSize == .zero)
            replacement.contentMinSize = .init(width: 500, height: 400)
            bridge.scheduleMinimumSizeReset(); replacement.close()
            let closeWrites = MinimumSizeProbe.writesByWindow[ObjectIdentifier(replacement), default: 0]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                precondition(MinimumSizeProbe.writesByWindow[ObjectIdentifier(replacement), default: 0] == closeWrites,
                    "A queued reset must not write a closed window")
                print("PASS queued sizing resets reject replaced and closed generated windows")
                window.close(); exit(0)
            }
        }
    }
}
