import AppKit
import SwiftUI

/// AppKit recycles visible rows; a large result set never creates one SwiftUI
/// view per scanned file. The immutable tree is built away from the main queue.
struct SimilarityFileTree: NSViewRepresentable {
    let snapshot: SimilarityTreeSnapshot
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
        coordinator.update(snapshot: snapshot, selectedID: selectedID, searching: searching, groupExpansion: groupExpansion)
    }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var outline: NSOutlineView?
        var roots: [SimilarityTreeNode] = []
        var nodes: [String: SimilarityTreeNode] = [:]
        var parents: [String: SimilarityTreeNode] = [:]
        var updating = false
        private var snapshotID: UUID?
        private var grouped = false
        private var expandedIDs = Set<String>()
        private var expansionTask: Task<Void, Never>?
        private var appliedGroupExpansionID: UUID?
        var select: (String?) -> Void = { _ in }
        var preview: (SimilarityFile) -> Void = { _ in }
        func update(snapshot: SimilarityTreeSnapshot, selectedID: String?, searching: Bool,
                    groupExpansion: SimilarityGroupExpansion?) {
            guard let outline else { return }
            let roots = snapshot.roots, changed = snapshotID != snapshot.id
            updating = true
            defer { updating = false }
            if changed {
                expansionTask?.cancel()
                let known = nodes, expanded = expandedIDs
                let groupTree = snapshot.grouped, changedKind = groupTree != grouped
                let clip = outline.enclosingScrollView?.contentView
                let origin = clip?.bounds.origin ?? .zero
                let visible = outline.rows(in: outline.visibleRect)
                var anchors: [(String, CGFloat)] = []
                if !changedKind, visible.location != NSNotFound {
                    for row in visible.location..<min(outline.numberOfRows, NSMaxRange(visible)) {
                        if let node = outline.item(atRow: row) as? SimilarityTreeNode {
                            anchors.append((node.id, outline.rect(ofRow: row).minY - origin.y))
                        }
                    }
                }
                self.roots = roots; nodes = snapshot.nodes; parents = snapshot.parents
                snapshotID = snapshot.id; grouped = groupTree; expandedIDs = []
                outline.reloadData()
                if groupTree, let groupExpansion {
                    // Preserve individual toggles for surviving groups. Newly
                    // formed groups follow the last bulk expansion choice.
                    let toExpand = roots.filter { known[$0.id] != nil ? expanded.contains($0.id) : groupExpansion.expanded }
                    expand(toExpand, recursively: true)
                } else if known.isEmpty || searching || changedKind {
                    outline.beginUpdates()
                    defer { outline.endUpdates() }
                    var budget = 200
                    func expand(_ node: SimilarityTreeNode, depth: Int) {
                        guard node.file == nil, !node.children.isEmpty, node.children.count <= budget, searching || depth < 2 else { return }
                        // Count the rows that expansion adds, not just groups.
                        // A single huge group must not expose 100,000 rows.
                        budget -= node.children.count; outline.expandItem(node)
                        for child in node.children { expand(child, depth: depth + 1) }
                    }
                    for root in roots { expand(root, depth: 0) }
                } else {
                    // Empty is a valid user choice: a redraw must not reopen
                    // every group after Collapse All.
                    for id in expanded { if let node = nodes[id] { outline.expandItem(node) } }
                }
                if let clip, !anchors.isEmpty {
                    outline.layoutSubtreeIfNeeded()
                    var restored = origin
                    for (id, offset) in anchors {
                        guard let node = nodes[id] else { continue }
                        let row = outline.row(forItem: node)
                        guard row >= 0 else { continue }
                        restored.y = outline.rect(ofRow: row).minY - offset
                        break
                    }
                    var bounds = clip.bounds; bounds.origin = restored
                    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                    outline.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            if let groupExpansion, appliedGroupExpansionID != groupExpansion.id {
                expansionTask?.cancel()
                if groupExpansion.expanded { expand(roots, recursively: true) }
                else { outline.collapseItem(nil, collapseChildren: true); expandedIDs = [] }
            }
            appliedGroupExpansionID = groupExpansion?.id
            if let selectedID, let node = nodes[selectedID] {
                var ancestors: [SimilarityTreeNode] = [], parent = parents[selectedID]
                while let item = parent { ancestors.append(item); parent = parents[item.id] }
                for parent in ancestors.reversed() { outline.expandItem(parent) }
                let row = outline.row(forItem: node)
                if row >= 0 && outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else if outline.selectedRow >= 0 && (outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode)?.file != nil {
                outline.deselectAll(nil)
            }
        }
        private func expand(_ roots: [SimilarityTreeNode], recursively: Bool) {
            guard let outline else { return }
            if nodes.count <= 2_000 {
                outline.beginUpdates()
                defer { outline.endUpdates() }
                for root in roots { outline.expandItem(root, expandChildren: recursively) }
                return
            }
            // Explicit Expand All remains available, but yields between batches
            // so a large result can still be searched, selected or collapsed.
            expansionTask = Task { @MainActor [weak self] in
                var pending = roots.reversed().map { $0 }
                while !pending.isEmpty {
                    guard let self, !Task.isCancelled, let outline = self.outline else { return }
                    self.updating = true
                    outline.beginUpdates()
                    for _ in 0..<16 {
                        guard let node = pending.popLast() else { break }
                        guard node.file == nil else { continue }
                        outline.expandItem(node)
                        if recursively { pending.append(contentsOf: node.children.reversed().filter { $0.file == nil }) }
                    }
                    outline.endUpdates()
                    self.updating = false
                    await Task.yield()
                }
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? SimilarityTreeNode { expandedIDs.insert(node.id) }
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? SimilarityTreeNode { expandedIDs.remove(node.id) }
        }
        deinit { expansionTask?.cancel() }
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
