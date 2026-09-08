// Mounts the production input bar only. No account data, API, browser model,
// network access or cloud submission is used by this UI fixture.
import SwiftUI

@main
struct SharedLinkInputUITestApp: App {
    @State private var url = ""
    @State private var passcode = ""
    @State private var width: CGFloat = 920
    @State private var submissions = 0
    @State private var submittedURL = ""

    var body: some Scene {
        WindowGroup("Shared Link Input UI Test") {
            GeometryReader { viewport in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Shared-link field focus · offline fixture").font(.title2.bold())
                    HStack {
                        Button("Narrow · ⌘1") { width = 280 }.keyboardShortcut("1")
                        Button("Compact · ⌘2") { width = 480 }.keyboardShortcut("2")
                        Button("Wide · ⌘3") { width = 920 }.keyboardShortcut("3")
                    }
                    Text("Type in the URL, then use ⌘1/⌘2/⌘3 without leaving the field. The caret and text selection should survive resizing.")
                        .foregroundStyle(.secondary)
                    SharedLinkInputBar(
                        url: $url, passcode: $passcode,
                        canSubmit: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onSubmit: { submissions += 1; submittedURL = url }
                    )
                    .frame(width: max(0, min(width, viewport.size.width - 68)))
                    .padding(10)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    Text("URL characters: \(url.count) · submissions: \(submissions)")
                    Text("Submitted URL: \(submittedURL)").textSelection(.enabled)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .defaultSize(width: 1020, height: 500)
    }
}
