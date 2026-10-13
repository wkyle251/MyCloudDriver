import AppKit
import SwiftUI

@main struct ActivityLogUITestApp: App {
    var body: some Scene {
        WindowGroup("Activity Log Fixture") { FixtureView() }
            .defaultSize(width: 720, height: 360)
    }
}

private struct FixtureView: View {
    @State private var log: ActivityLogBuffer = {
        var buffer = ActivityLogBuffer()
        buffer.append("Downloading generated report.mp4\nWarning: connection interrupted; retrying\nDEBUG resumed at byte 1024\n")
        buffer.record("Some downloads were interrupted: failed to download generated-report.mp4: File name too long (os error 63)", level: .error)
        return buffer
    }()
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloads").font(.title2.weight(.semibold))
            Text("Synthetic downloads only").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Add Error") { log.record("Generated download interrupted; waiting to retry.", level: .error) }
                Button("Add Info") { log.append("Saved generated report.mp4\n") }
            }
            ActivityLogPanel(log: log, busy: true, expanded: $expanded,
                clear: { log.clear() }, status: AnyView(Text("Downloads continuing").font(.caption).lineLimit(1)))
        }.padding(12).frame(minWidth: 480, minHeight: 360)
    }
}
