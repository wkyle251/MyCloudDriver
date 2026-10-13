import AppKit
import SwiftUI

/// Built once for each right-click. SwiftUI row/progress updates replace only
/// the factory for the next opening, never the active menu or its submenus.
struct BrowserNativeContextMenu: NSViewRepresentable {
    let makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> MenuTarget {
        let view = MenuTarget()
        view.setAccessibilityLabel("Item actions")
        return view
    }
    func updateNSView(_ view: MenuTarget, context: Context) { view.makeMenu = makeMenu }
    static func dismantleNSView(_ view: MenuTarget, coordinator: ()) {
        view.activeMenu?.cancelTracking(); view.makeMenu = nil
    }

    final class MenuTarget: NSView {
        var makeMenu: (() -> NSMenu)?
        var menuAtPoint: ((CGPoint) -> NSMenu?)?
        var acceptsPoint: ((CGPoint) -> Bool)?
        var isCanvas = false
        private(set) var activeMenu: NSMenu?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  bounds.contains(convert(point, from: superview)) else { return nil }
            guard acceptsPoint?(convert(point, from: superview)) != false else { return nil }
            return self
        }
        override func rightMouseDown(with event: NSEvent) { present(at: convert(event.locationInWindow, from: nil)) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
            else { super.mouseDown(with: event) }
        }
        func present(at point: NSPoint) {
            guard activeMenu == nil, let menu = menuAtPoint?(point) ?? makeMenu?() else { return }
            present(menu, at: point)
        }
        func present(_ menu: NSMenu, at point: NSPoint) {
            guard activeMenu == nil, window != nil else { return }
            activeMenu = menu
            defer { activeMenu = nil }
            menu.popUp(positioning: nil, at: point, in: self)
        }
        override func isAccessibilityElement() -> Bool { !isCanvas }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            [NSAccessibilityCustomAction(name: "Show Context Menu", handler: { [weak self] in
                self?.accessibilityPerformShowMenu() ?? false
            })]
        }
        override func accessibilityPerformShowMenu() -> Bool {
            guard window != nil, makeMenu != nil || menuAtPoint != nil else { return false }
            present(at: .init(x: bounds.midX, y: bounds.midY)); return true
        }
    }
}

/// One native menu host for a fixed-height outline, rather than an AppKit view
/// in every materialized row. Hit testing resolves the row only on right-click;
/// scrolling and progress updates do not rebuild an open menu.
@MainActor final class BrowserNativeMenuPresenter: ObservableObject {
    fileprivate weak var target: BrowserNativeContextMenu.MenuTarget?
    fileprivate var rowHeight: CGFloat = 29

    func show(row: Int) {
        guard let target, target.activeMenu == nil,
              let menu = target.menuAtPoint?(.init(x: 0, y: (CGFloat(row) + 0.5) * rowHeight)) else { return }
        let visible = target.visibleRect
        let y = min(max((CGFloat(row) + 0.5) * rowHeight, visible.minY + 1), visible.maxY - 1)
        target.present(menu, at: .init(x: visible.minX + min(24, visible.width / 2), y: y))
    }
}

struct BrowserNativeContextMenuCanvas: NSViewRepresentable {
    let rowHeight: CGFloat
    let rowCount: Int
    let presenter: BrowserNativeMenuPresenter
    var acceptsRow: (Int) -> Bool = { _ in true }
    let makeMenu: (Int) -> NSMenu?

    static func rowIndex(at point: CGPoint, rowHeight: CGFloat, rowCount: Int) -> Int? {
        guard rowHeight.isFinite, rowHeight > 0, point.y.isFinite, point.y >= 0 else { return nil }
        let index = floor(point.y / rowHeight)
        guard index < CGFloat(rowCount), index < CGFloat(Int.max) else { return nil }
        return Int(index)
    }

    func makeNSView(context: Context) -> BrowserNativeContextMenu.MenuTarget {
        let view = BrowserNativeContextMenu.MenuTarget()
        view.isCanvas = true
        return view
    }
    func updateNSView(_ view: BrowserNativeContextMenu.MenuTarget, context: Context) {
        presenter.target = view; presenter.rowHeight = rowHeight
        view.acceptsPoint = { point in
            guard let index = Self.rowIndex(at: point, rowHeight: rowHeight, rowCount: rowCount) else { return false }
            return acceptsRow(index)
        }
        view.menuAtPoint = { point in
            guard let index = Self.rowIndex(at: point, rowHeight: rowHeight, rowCount: rowCount) else { return nil }
            return makeMenu(index)
        }
    }
    static func dismantleNSView(_ view: BrowserNativeContextMenu.MenuTarget, coordinator: ()) {
        view.activeMenu?.cancelTracking()
        view.menuAtPoint = nil; view.acceptsPoint = nil
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
