import AppKit
import SwiftUI

/// Built once for each right-click. SwiftUI row/progress updates replace only
/// the factory for the next opening, never the active menu or its submenus.
struct BrowserNativeContextMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> MenuTarget {
        let view = MenuTarget()
        view.setAccessibilityLabel("Folder actions")
        return view
    }
    func updateNSView(_ view: MenuTarget, context: Context) { view.makeMenu = makeMenu }
    static func dismantleNSView(_ view: MenuTarget, coordinator: ()) {
        view.activeMenu?.cancelTracking(); view.makeMenu = nil
    }

    final class MenuTarget: NSView {
        var makeMenu: (() -> NSMenu)?
        private(set) var activeMenu: NSMenu?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) { present(at: convert(event.locationInWindow, from: nil)) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }
        private func present(at point: NSPoint) {
            guard activeMenu == nil, let menu = makeMenu?(), window != nil else { return }
            activeMenu = menu
            defer { activeMenu = nil }
            menu.popUp(positioning: nil, at: point, in: self)
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            [NSAccessibilityCustomAction(name: "Show Folder Menu", handler: { [weak self] in
                self?.accessibilityPerformShowMenu() ?? false
            })]
        }
        override func accessibilityPerformShowMenu() -> Bool {
            guard window != nil, makeMenu != nil else { return false }
            present(at: .init(x: bounds.midX, y: bounds.midY)); return true
        }
    }
}

@MainActor final class BrowserNativeMenu: NSMenu {
    override init(title: String = "Folder actions") {
        super.init(title: title)
        autoenablesItems = false
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult
    func addAction(_ title: String, symbol: String? = nil, enabled: Bool = true,
                   action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title: title, action: action)
        item.isEnabled = enabled
        if let symbol { item.image = BrowserContextMenuStyle.icon(named: symbol) }
        addItem(item)
        return item
    }
    func addSubmenu(_ title: String, symbol: String, enabled: Bool, submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = BrowserContextMenuStyle.icon(named: symbol)
        item.isEnabled = enabled; item.submenu = submenu
        addItem(item)
    }
    private final class ActionItem: NSMenuItem {
        let performAction: () -> Void
        init(title: String, action: @escaping () -> Void) {
            performAction = action
            super.init(title: title, action: #selector(invoke), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        @objc private func invoke() { if isEnabled { performAction() } }
    }
}
