import AppKit
import SwiftUI

/// AppKit recycles visible rows; a large result set never creates one SwiftUI
/// view per scanned file. The immutable tree is built away from the main queue.
struct SimilarityFileTree: NSViewRepresentable {
    let roots: [SimilarityTreeNode]
    let selectedID: String?
    let searching: Bool
    var groupExpansion: SimilarityGroupExpansion? = nil
    let select: (String?) -> Void
    let preview: (SimilarityFile) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), outline = ResultOutlineView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .controlBackgroundColor
        outline.rowHeight = 32; outline.intercellSpacing = .init(width: 0, height: 2)
        outline.usesAlternatingRowBackgroundColors = true; outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false; outline.indentationPerLevel = 15
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.setAccessibilityLabel("Scanned files")
        let name = NSTableColumn(identifier: .init("name")); name.title = "Name"; name.width = 245; name.minWidth = 130
        let size = NSTableColumn(identifier: .init("size")); size.title = "Size"; size.width = 76; size.minWidth = 65; size.maxWidth = 90
        outline.addTableColumn(name); outline.addTableColumn(size); outline.outlineTableColumn = name
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator; outline.doubleAction = #selector(Coordinator.doubleClick)
        outline.action = #selector(Coordinator.singleClick)
        outline.didFocus = { [weak coordinator = context.coordinator] in coordinator?.selectCurrentRow() }
        outline.preview = { [weak coordinator = context.coordinator] in coordinator?.previewSelection() }
        scroll.documentView = outline; context.coordinator.outline = outline
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.select = select; coordinator.preview = preview
        coordinator.update(roots: roots, selectedID: selectedID, searching: searching, groupExpansion: groupExpansion)
    }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: NSOutlineView?
        var roots: [SimilarityTreeNode] = []
        var nodes: [String: SimilarityTreeNode] = [:]
        var parents: [String: [SimilarityTreeNode]] = [:]
        var updating = false
        private var appliedGroupExpansionID: UUID?
        var select: (String?) -> Void = { _ in }
        var preview: (SimilarityFile) -> Void = { _ in }
        func update(roots: [SimilarityTreeNode], selectedID: String?, searching: Bool,
                    groupExpansion: SimilarityGroupExpansion?) {
            guard let outline else { return }
            let changed = self.roots.count != roots.count || zip(self.roots, roots).contains { $0 !== $1 }
            updating = true
            defer { updating = false }
            if changed {
                let known = Set(nodes.keys)
                let expanded = Set(nodes.values.filter { $0.file == nil && outline.isItemExpanded($0) }.map(\.id))
                let groupTree = roots.contains { $0.group != nil }
                let changedKind = groupTree != self.roots.contains { $0.group != nil }
                self.roots = roots; nodes = [:]; parents = [:]
                func visit(_ node: SimilarityTreeNode, ancestors: [SimilarityTreeNode]) {
                    nodes[node.id] = node; parents[node.id] = ancestors
                    for child in node.children { visit(child, ancestors: ancestors + [node]) }
                }
                for root in roots { visit(root, ancestors: []) }
                outline.reloadData()
                if groupTree, let groupExpansion {
                    // Preserve individual toggles for surviving groups. Newly
                    // formed groups follow the last bulk expansion choice.
                    for root in roots {
                        if known.contains(root.id) ? expanded.contains(root.id) : groupExpansion.expanded {
                            outline.expandItem(root, expandChildren: true)
                        }
                    }
                } else if known.isEmpty || searching || changedKind {
                    var budget = 200
                    func expand(_ node: SimilarityTreeNode, depth: Int) {
                        guard node.file == nil, budget > 0, searching || depth < 2 else { return }
                        budget -= 1; outline.expandItem(node)
                        for child in node.children { expand(child, depth: depth + 1) }
                    }
                    for root in roots { expand(root, depth: 0) }
                } else {
                    // Empty is a valid user choice: a redraw must not reopen
                    // every group after Collapse All.
                    for id in expanded { if let node = nodes[id] { outline.expandItem(node) } }
                }
            }
            if let groupExpansion, appliedGroupExpansionID != groupExpansion.id {
                if groupExpansion.expanded { outline.expandItem(nil, expandChildren: true) }
                else { outline.collapseItem(nil, collapseChildren: true) }
            }
            appliedGroupExpansionID = groupExpansion?.id
            if let selectedID, let node = nodes[selectedID] {
                for parent in parents[selectedID] ?? [] { outline.expandItem(parent) }
                let row = outline.row(forItem: node)
                if row >= 0 && outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else if outline.selectedRow >= 0 && (outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode)?.file != nil {
                outline.deselectAll(nil)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SimilarityTreeNode)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? SimilarityTreeNode)?.children[index] ?? roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SimilarityTreeNode)?.file == nil }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SimilarityTreeNode, let column = tableColumn else { return nil }
            let cellID = column.identifier
            let cell = (outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? makeCell(cellID)
            if cellID.rawValue == "name" {
                cell.textField?.stringValue = node.name
                cell.imageView?.image = NSImage(systemSymbolName: node.group == nil ? node.file?.symbol ?? "folder.fill" : "square.stack.3d.up.fill", accessibilityDescription: nil)
                cell.imageView?.contentTintColor = node.file?.state == "failed" || node.file?.state == "unsupported" ? .systemOrange : NSColor(FinderAppearance.accent)
                cell.toolTip = node.path
                cell.setAccessibilityLabel(node.name + (node.group.map { ", \($0.strengthLabel)" } ?? ""))
            } else {
                cell.textField?.stringValue = node.file.map { SimilarityScanProgress.bytes($0.bytes) } ?? "\(node.fileCount) \(node.fileCount == 1 ? "file" : "files")"
                cell.textField?.textColor = .secondaryLabelColor
            }
            return cell
        }
        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = id
            let label = NSTextField(labelWithString: ""); label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle; label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            if id.rawValue == "name" {
                let image = NSImageView(); image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image); cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18),
                    label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7)])
            } else {
                label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                label.alignment = .right; label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            selectCurrentRow()
        }
        @objc func singleClick() {
            guard let outline, outline.clickedRow >= 0 else { return }
            // Clicking an already-selected reference returns action focus from
            // its match list even when AppKit does not change the selection.
            selectCurrentRow()
        }
        func selectCurrentRow() {
            guard !updating, let outline else { return }
            let node = outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode
            select(node.flatMap { $0.file?.id ?? ($0.group != nil ? $0.id : nil) })
        }
        @objc func doubleClick() {
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? SimilarityTreeNode else { return }
            if let file = node.file { preview(file) }
            else if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
        func previewSelection() {
            guard let outline, outline.selectedRow >= 0, let file = (outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode)?.file else { return }
            preview(file)
        }
    }
}

private final class ResultOutlineView: NSOutlineView {
    var preview: (() -> Void)?
    var didFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didFocus?() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if !event.isARepeat { preview?() }; return
        }
        super.keyDown(with: event)
    }
}

/// These results live in independently hosted windows. Handle the shortcut
/// before the main browser's menu, scoped to this window and its selection.
struct SimilarityResultTrashShortcut: NSViewRepresentable {
    let enabled: Bool
    let perform: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.enabled = enabled; view.perform = perform }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var enabled = false
        var perform: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      NSApp.keyWindow === window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor, !window.isSheet,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !(window.firstResponder is NSTextField),
                      (window.firstResponder as? NSTextView)?.isEditable != true,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      event.keyCode == 51 || event.keyCode == 117 else { return event }
                // Never let a results-window shortcut fall through to another
                // window's file action, including while confirmation is open.
                if self.enabled && !event.isARepeat { self.perform?() }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
