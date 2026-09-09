import AppKit
import SwiftUI
@preconcurrency import QuickLookUI

/// Keeps the system preview panel alive while its selected cloud file changes.
/// Only the pending/error view is ours; loaded files use Quick Look's renderer.
@MainActor
final class QuickLookPreviewCoordinator: NSResponder, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private(set) var itemID: String?
    private var item: NamedQuickLookItem?
    private weak var ownerWindow: NSWindow?
    private var previousResponder: NSResponder?
    private var overlay: NSHostingView<QuickLookPendingView>?
    private var keyMonitor: Any?
    var onMove: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?

    var isActive: Bool { itemID != nil }
    var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return false }
        return panel.isVisible && owns(panel)
    }

    func owns(_ window: NSWindow) -> Bool {
        guard let panel = window as? QLPreviewPanel else { return false }
        return (panel.currentController as AnyObject?) === self
    }

    func prepare(in window: NSWindow?) {
        guard let window, !(window is QLPreviewPanel), ownerWindow !== window else { return }
        detach()
        ownerWindow = window
        previousResponder = window.nextResponder
        nextResponder = previousResponder
        window.nextResponder = self
    }

    @discardableResult
    func showLoading(fileID: String, name: String, in window: NSWindow? = nil) -> Bool {
        showPending(fileID: fileID, name: name, state: .loading, in: window)
    }

    func showFailure(_ message: String) {
        guard let itemID, let name = item?.previewItemTitle, isVisible else { return }
        _ = showPending(fileID: itemID, name: name, state: .failed(message))
    }

    func showFolder(fileID: String, name: String) {
        _ = showPending(fileID: fileID, name: name, state: .folder)
    }

    private func showPending(fileID: String, name: String, state: QuickLookPendingState,
                             in window: NSWindow? = nil) -> Bool {
        let wasVisible = isVisible
        prepare(in: window ?? ownerWindow ?? NSApp?.mainWindow ?? NSApp?.keyWindow)
        itemID = fileID
        item = NamedQuickLookItem(url: nil, title: name)
        guard let window = ownerWindow, window.isVisible, let panel = QLPreviewPanel.shared() else { return false }
        if !wasVisible { window.makeKeyAndOrderFront(nil) }
        panel.updateController()
        if !wasVisible { panel.makeKeyAndOrderFront(nil) }
        guard owns(panel) else { return false }
        reload(panel)
        // macOS displays "No items selected" for a nil URL. Cover only the
        // preview content while preserving the system close/fullscreen strip.
        guard let content = panel.contentView else { return false }
        let view = NSHostingView(rootView: QuickLookPendingView(name: name, state: state,
            retry: { [weak self] in self?.onRetry?() }))
        overlay?.removeFromSuperview()
        view.frame = CGRect(x: content.bounds.minX, y: content.bounds.minY,
                            width: content.bounds.width, height: max(0, content.bounds.height - 44))
        view.autoresizingMask = [.width, .height]
        content.addSubview(view, positioned: .above, relativeTo: nil)
        overlay = view
        return true
    }

    func present(_ fileURL: URL, name: String) -> Bool {
        guard isActive, isVisible, let panel = QLPreviewPanel.shared() else { return false }
        item = NamedQuickLookItem(url: fileURL, title: name)
        reload(panel)
        panel.refreshCurrentPreviewItem()
        overlay?.removeFromSuperview()
        overlay = nil
        return true
    }

    private func reload(_ panel: QLPreviewPanel) {
        let frame = panel.frame
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        if !panel.isInFullScreenMode { panel.setFrame(frame, display: true) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        isActive && ownerWindow?.isVisible == true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = event.window ?? NSApp.keyWindow, self.owns(window) else { return event }
                return self.handle(event, in: window) ? nil : event
            }
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        removePendingUI()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, !self.isVisible else { return }
            self.onClose?()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard owns(sender) else { return true }
        closeRequested()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, owns(window), isActive else { return }
        closeRequested()
    }

    private func closeRequested() {
        if let onClose { onClose() } else { dismiss() }
    }

    func dismiss() {
        let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
        let owned = panel.map(owns) == true
        itemID = nil
        item = nil
        removePendingUI()
        if owned { panel?.orderOut(nil) }
        detach()
    }

    private func removePendingUI() {
        overlay?.removeFromSuperview()
        overlay = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func detach() {
        if let window = ownerWindow, window.nextResponder === self { window.nextResponder = previousResponder }
        ownerWindow = nil
        previousResponder = nil
        nextResponder = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { item == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { item }

    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let action = FinderQuickLookKeyboard.action(keyCode: event.keyCode,
            modifiers: event.modifierFlags, isRepeat: event.isARepeat,
            isFileWindow: false, isOwnedPreviewPanel: owns(window),
            hasSheet: window.attachedSheet != nil,
            isTextInput: (window.firstResponder as? NSTextView)?.isEditable == true) else { return false }
        switch action {
        case .previous: onMove?(-1)
        case .next: onMove?(1)
        case .toggle, .cancel: closeRequested()
        case .consumeRepeat: break
        }
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let panel, let event, event.type == .keyDown else { return false }
        return handle(event, in: panel)
    }
}

private final class NamedQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL?, title: String) { previewItemURL = url; previewItemTitle = title }
}

private enum QuickLookPendingState {
    case loading, failed(String), folder
}

private struct QuickLookPendingView: View {
    let name: String
    let state: QuickLookPendingState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch state {
            case .loading: ProgressView().controlSize(.large)
            case .failed: Image(systemName: "exclamationmark.circle").font(.largeTitle).foregroundStyle(.secondary)
            case .folder: Image(systemName: "folder.fill").font(.system(size: 52)).foregroundStyle(.blue)
            }
            Text(name).font(.headline).lineLimit(2).truncationMode(.middle)
            switch state {
            case .loading: Text("Loading preview…").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again", action: retry).buttonStyle(.bordered)
            case .folder: Text("Folder").foregroundStyle(.secondary)
            }
            Text("↑ ↓ to browse · Space or Esc to close")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
