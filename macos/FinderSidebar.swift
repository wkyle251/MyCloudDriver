import AppKit
import SwiftUI

enum FinderSidebarHoverPolicy {
    static func canReveal(automaticallyHidden: Bool, pressedMouseButtons: Int) -> Bool {
        automaticallyHidden && pressedMouseButtons == 0
    }
}

/// A reserved edge strip prevents hover detection from stealing file clicks.
/// Revealing the sidebar overlays content; it never reflows a row mid-drag.
struct FinderSidebarLayout<Sidebar: View, Workspace: View>: View {
    let automaticallyHidden: Bool
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let workspace: () -> Workspace
    @State private var revealed = false
    @State private var pendingHover: Task<Void, Never>?
    static var edgeWidth: CGFloat { 8 }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(192, max(156, geometry.size.width * 0.2))
            let hidesSidebar = automaticallyHidden || geometry.size.width < 880
            HStack(spacing: 0) {
                if hidesSidebar {
                    Rectangle().fill(FinderAppearance.sidebarBackground)
                        .overlay { Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 2, height: 26) }
                        .frame(width: Self.edgeWidth)
                        .contentShape(Rectangle())
                        .onHover { inside in handleHover(inside, revealing: true, autoHide: hidesSidebar) }
                        .help(automaticallyHidden ? "Reveal sidebar · Option-Command-S keeps it visible" : "Reveal sidebar · widen this window to keep it visible")
                } else {
                    scrollableSidebar(height: geometry.size.height).frame(width: sidebarWidth)
                    Divider()
                }
                workspace().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .leading) {
                if hidesSidebar && revealed {
                    scrollableSidebar(height: geometry.size.height).frame(width: sidebarWidth)
                        .background(FinderAppearance.sidebarBackground)
                        .overlay(alignment: .trailing) { Divider() }
                        .shadow(color: .black.opacity(0.15), radius: 12, x: 6)
                        .onHover { inside in handleHover(inside, revealing: false, autoHide: hidesSidebar) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.16), value: revealed)
            .onChange(of: hidesSidebar) { _ in pendingHover?.cancel(); revealed = false }
        }
        .onChange(of: automaticallyHidden) { _ in
            pendingHover?.cancel()
            revealed = false
        }
        .onDisappear { pendingHover?.cancel() }
    }

    private func scrollableSidebar(height: CGFloat) -> some View {
        ScrollView(.vertical) { sidebar().frame(minHeight: height) }
            .scrollIndicators(.hidden)
            .background(FinderAppearance.sidebarBackground)
    }

    private func handleHover(_ inside: Bool, revealing: Bool, autoHide: Bool) {
        pendingHover?.cancel()
        guard autoHide else { return }
        if inside && !revealing { return }
        // Finder/local and in-app drags must keep their existing drop target.
        if inside && !FinderSidebarHoverPolicy.canReveal(automaticallyHidden: autoHide,
                                                        pressedMouseButtons: NSEvent.pressedMouseButtons) { return }
        pendingHover = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: inside ? 250_000_000 : 400_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            // A drag may have started during the dwell delay.
            guard !inside || FinderSidebarHoverPolicy.canReveal(automaticallyHidden: autoHide,
                                                               pressedMouseButtons: NSEvent.pressedMouseButtons) else { return }
            revealed = inside
        }
    }
}

struct FinderSidebarTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(FinderAppearance.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
            }
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .background(selected ? FinderAppearance.accent.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).pointingHandCursor()
        .foregroundStyle(selected ? FinderAppearance.accent : Color.primary)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Compact paired actions have full accessibility names and immediate hover labels.
/// Saved and saving states occupy the same fixed button footprint.
struct FinderRowAction: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    var busy = false
    var enabled = true
    var side: CGFloat = 24
    var hintOnRight = false
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(hovered && enabled ? 0.16 : 0.055))
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            }
            .frame(width: side, height: side)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).pointingHandCursor()
        .foregroundStyle(tint)
        .disabled(!enabled || busy)
        .onHover { hovered = $0; onHover($0) }
        .onDisappear { hovered = false; onHover(false) }
        .overlay(alignment: hintOnRight ? .leading : .trailing) {
            if hovered {
                // Stay beside the icon, inside the row's clipped scroll view.
                // Only the hovered action draws a label; no native views or
                // per-row geometry tracking are needed during scrolling.
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .padding(hintOnRight ? .leading : .trailing, side + 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .zIndex(hovered ? 1 : 0)
        .help(title)
        .accessibilityLabel(title)
    }
}
