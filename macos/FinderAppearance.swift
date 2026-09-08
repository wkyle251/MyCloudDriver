import AppKit
import SwiftUI

enum FinderAppearance {
    static let accent = Color(red: 0.08, green: 0.42, blue: 0.95)
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.075, green: 0.12, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.92, green: 0.96, blue: 1, alpha: 1)
    })
}

/// The app's unstyled native push buttons also advertise their click target.
struct FinderButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.bordered).pointingHandCursor()
    }
}

/// Nested/overlapping hover targets share one balanced cursor-stack entry.
/// A disappearing lazy row releases ownership just like a pointer exit.
@MainActor
final class FinderCursorTracker {
    static let shared = FinderCursorTracker()
    private var owners = Set<UUID>()
    private let push: () -> Void
    private let pop: () -> Void

    init(push: @escaping () -> Void = { NSCursor.pointingHand.push() },
         pop: @escaping () -> Void = { NSCursor.pop() }) {
        self.push = push
        self.pop = pop
    }

    func setActive(_ active: Bool, owner: UUID) {
        if active {
            let wasEmpty = owners.isEmpty
            if owners.insert(owner).inserted && wasEmpty { push() }
        } else if owners.remove(owner) != nil && owners.isEmpty {
            pop()
        }
    }
}

/// SwiftUI hover tracking avoids embedding an AppKit view in every button.
/// Native cursor rectangles caused repeated view/layout work during scrolling.
private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovered = hovering
                FinderCursorTracker.shared.setActive(hovering && isEnabled, owner: owner)
            }
            .onChange(of: isEnabled) { enabled in
                FinderCursorTracker.shared.setActive(isHovered && enabled, owner: owner)
            }
            .onDisappear { FinderCursorTracker.shared.setActive(false, owner: owner) }
    }
}

extension View {
    @ViewBuilder
    func pointingHandCursor() -> some View {
        #if BROWSER_SCROLL_PROFILING
        if BrowserScrollDiagnostics.disableCursor { self }
        else { modifier(PointingHandCursor()) }
        #else
        modifier(PointingHandCursor())
        #endif
    }
}
