import AppKit
import AVFoundation
import SwiftUI

/// Displays the production seek control with deterministic buffered ranges.
/// No account, network, saved preferences or user media are used.
private struct TimelineSample: NSViewRepresentable {
    @Binding var value: Double
    var ranges: [ClosedRange<Double>]
    var volume = false
    func makeNSView(context: Context) -> MediaSliderControl { MediaSliderControl() }
    func updateNSView(_ slider: MediaSliderControl, context: Context) {
        slider.maximum = volume ? 1 : 180
        slider.isEnabled = true; slider.isVolume = volume
        slider.bufferedRanges = ranges
        if !slider.tracking { slider.value = value }
        slider.onScrub = { value = $0 }; slider.onCommit = { newValue, _ in value = newValue }
        slider.setAccessibilityLabel(volume ? "Preview volume" : "Playback position")
    }
}

private struct TimelineSamples: View {
    @State private var start = 18.0
    @State private var seek = 90.0
    @State private var empty = 0.0
    @State private var volume = 0.65
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Media preview timeline").font(.title2.bold())
            Text("Played · Buffered · Remaining").foregroundStyle(.secondary)
            sample("Playing", position: $start, ranges: [0...0.45])
            sample("After seeking — buffer gaps remain visible", position: $seek, ranges: [0...0.15, 0.5...0.6, 0.75...0.88])
            sample("Waiting for data", position: $empty, ranges: [])
            HStack {
                Text("Volume")
                TimelineSample(value: $volume, ranges: [], volume: true).frame(width: 160, height: 18)
                Text("\(Int(volume * 100))%").monospacedDigit()
            }
            Text("Drag or use arrow keys. Resize this window to check track alignment.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 380, minHeight: 370)
            .background(Color(nsColor: .controlBackgroundColor))
    }
    private func sample(_ title: String, position: Binding<Double>, ranges: [ClosedRange<Double>]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text(MediaPlaybackController.time(position.wrappedValue)).monospacedDigit() }
            TimelineSample(value: position, ranges: ranges).frame(height: 18)
        }
    }
}

@main @MainActor final class MediaTimelineUITestApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    static func main() {
        let app = NSApplication.shared, delegate = MediaTimelineUITestApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Timeline QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let fixture = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: ""), submenu = NSMenu()
        for (name, selector) in [("Toggle Appearance", #selector(toggleAppearance)), ("Compact Width", #selector(compact))] {
            let item = NSMenuItem(title: name, action: selector, keyEquivalent: ""); item.target = self; submenu.addItem(item)
        }
        fixture.submenu = submenu; menu.addItem(fixture); NSApp.mainMenu = menu
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Media Timeline QA"; window.contentView = NSHostingView(rootView: TimelineSamples())
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc func toggleAppearance() { NSApp.appearance = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua) }
    @objc func compact() { window.setContentSize(.init(width: 400, height: 420)) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
