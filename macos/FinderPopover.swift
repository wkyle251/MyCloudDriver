import AppKit
import SwiftUI

/// Transient workflow UI can be dismissed before its anchor or workspace is
/// replaced. Existing SwiftUI popovers may observe this notification too.
enum FinderPopover {
    static let dismissAllNotification = Notification.Name("MyCloudDriver.dismissPopovers")
    @MainActor private static var owners: [AnyHashable: UUID] = [:]
    @MainActor fileprivate static func claim(_ id: AnyHashable, token: UUID) { owners[id] = token }
    @MainActor fileprivate static func owns(_ id: AnyHashable, token: UUID) -> Bool { owners[id] == token }
    @MainActor fileprivate static func release(_ id: AnyHashable, token: UUID) {
        if owns(id, token: token) { owners.removeValue(forKey: id) }
    }
    @MainActor static func dismissAll() {
        NotificationCenter.default.post(name: dismissAllNotification, object: nil)
    }
}

extension View {
    /// A native popover with a viewport pinned for each presentation. Content
    /// updates stay inside that viewport instead of animating the window size.
    /// Content closes through `isPresented`; its inherited environment is kept.
    @MainActor func finderPopover<Content: View>(isPresented: Binding<Bool>, contentSize: CGSize,
                                                presentationID: AnyHashable? = nil,
                                                arrowEdge: Edge = .top,
                                                @ViewBuilder content: @escaping () -> Content) -> some View {
        background(FinderPopoverAnchor(isPresented: isPresented, contentSize: contentSize,
                                       presentationID: presentationID, arrowEdge: arrowEdge, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}

private struct FinderPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let contentSize: CGSize
    let presentationID: AnyHashable?
    let arrowEdge: Edge
    @ViewBuilder let content: () -> Content
    @Environment(\.self) private var environment
    @State private var defaultPresentationID = UUID()

    func makeCoordinator() -> FinderPopoverController { FinderPopoverController() }
    func makeNSView(context: Context) -> FinderPopoverAnchorView {
        let view = FinderPopoverAnchorView()
        view.controller = context.coordinator
        return view
    }
    func updateNSView(_ view: FinderPopoverAnchorView, context: Context) {
        context.coordinator.update(anchor: view, isPresented: $isPresented, contentSize: contentSize,
            presentationID: presentationID ?? AnyHashable(defaultPresentationID), arrowEdge: arrowEdge,
            content: isPresented ? AnyView(content().environment(\.self, environment)) : nil)
    }
    static func dismantleNSView(_ view: FinderPopoverAnchorView, coordinator: FinderPopoverController) {
        view.controller = nil
        coordinator.invalidate()
    }
}

@MainActor final class FinderPopoverAnchorView: NSView {
    weak var controller: FinderPopoverController?
    override var intrinsicContentSize: NSSize { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.anchorWindowChanged()
    }
}

/// All AppKit presentation and root updates are deferred out of SwiftUI's
/// update/layout pass. A detached anchor can never reopen a queued popover.
@MainActor final class FinderPopoverController: NSObject, NSPopoverDelegate {
    private(set) var popover: NSPopover?
    private(set) var presentationSize: CGSize?
    private weak var anchor: FinderPopoverAnchorView?
    private weak var ownerWindow: NSWindow?
    private var host: NSHostingController<AnyView>?
    private var binding: Binding<Bool>?
    private var content: AnyView?
    private var requestedSize = CGSize(width: 400, height: 300)
    private var arrowEdge = Edge.top
    private var requested = false
    private var suppressUntilFalse = false
    private let ownerToken = UUID()
    private var ownershipID = AnyHashable(UUID())
    private var invalidated = false
    private var scheduled = false
    private var dismissObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var sheetBeginObserver: NSObjectProtocol?
    private var sheetEndObserver: NSObjectProtocol?

    override init() {
        super.init()
        dismissObserver = NotificationCenter.default.addObserver(forName: FinderPopover.dismissAllNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
    }

    func update(anchor: FinderPopoverAnchorView, isPresented: Binding<Bool>, contentSize: CGSize,
                presentationID: AnyHashable? = nil, arrowEdge: Edge, content: AnyView?) {
        guard !invalidated else { return }
        if let presentationID, ownershipID != presentationID {
            FinderPopover.release(ownershipID, token: ownerToken)
            ownershipID = presentationID
        }
        self.anchor = anchor; binding = isPresented; self.content = content
        requestedSize = Self.validSize(contentSize); self.arrowEdge = arrowEdge
        if !isPresented.wrappedValue { suppressUntilFalse = false }
        requested = isPresented.wrappedValue && !suppressUntilFalse
        // A departing view's false update must never steal the newer anchor's
        // ownership of the same presentation binding.
        if requested { FinderPopover.claim(ownershipID, token: ownerToken) }
        else if !isPresented.wrappedValue { FinderPopover.release(ownershipID, token: ownerToken) }
        schedule()
    }

    func anchorWindowChanged() {
        guard !invalidated else { return }
        if let ownerWindow, anchor?.window !== ownerWindow { dismiss() }
        else { schedule() }
    }

    private func schedule() {
        guard !scheduled, !invalidated else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.scheduled = false
            self.reconcile()
        }
    }

    private func reconcile() {
        guard requested, let content else { closeCurrent(); return }
        guard FinderPopover.owns(ownershipID, token: ownerToken) else { closeCurrent(); return }
        guard let anchor, let window = anchor.window, window.isVisible else { return }
        if window.attachedSheet != nil || window.isSheet {
            if popover != nil { dismiss() }
            else { observeOwnerWindow(window) }
            return
        }
        if let popover, popover.isShown, let size = presentationSize {
            host?.rootView = Self.root(content, size: size)
            return
        }
        closeCurrent()
        let size = requestedSize
        let host = NSHostingController(rootView: Self.root(content, size: size))
        host.sizingOptions = []
        host.preferredContentSize = size
        host.view.setFrameSize(size)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = host
        popover.contentSize = size
        popover.delegate = self
        self.host = host; self.popover = popover; presentationSize = size
        observeOwnerWindow(window)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: Self.nativeEdge(arrowEdge))
        // AppKit may decline an offscreen/invisible anchor. Do not retain a
        // phantom presentation that will reopen on a later unrelated update.
        if !popover.isShown { dismiss() }
    }

    private func observeOwnerWindow(_ window: NSWindow) {
        guard ownerWindow !== window else { return }
        removeWindowObservers()
        ownerWindow = window
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        sheetBeginObserver = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.popover != nil { self?.dismiss() } }
            }
        sheetEndObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
            object: window.sheetParent ?? window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
    }

    func dismiss() {
        guard !invalidated else { return }
        requested = false; suppressUntilFalse = true
        closeCurrent()
        resetBinding()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        requested = false; suppressUntilFalse = true
        closeCurrent()
        resetBinding()
    }

    private func resetBinding() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.requested, self.suppressUntilFalse,
                  FinderPopover.owns(self.ownershipID, token: self.ownerToken),
                  let binding = self.binding else { return }
            // Consume our own reset immediately. The user may reopen before
            // SwiftUI renders the intervening false value; it must not leave
            // that fresh request suppressed until another click.
            self.suppressUntilFalse = false
            if binding.wrappedValue { binding.wrappedValue = false }
            FinderPopover.release(self.ownershipID, token: self.ownerToken)
        }
    }

    private func closeCurrent() {
        removeWindowObservers()
        let previous = popover
        popover = nil; host = nil; presentationSize = nil; ownerWindow = nil
        previous?.delegate = nil
        previous?.close()
    }

    private func removeWindowObservers() {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        if let sheetBeginObserver { NotificationCenter.default.removeObserver(sheetBeginObserver); self.sheetBeginObserver = nil }
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver); self.sheetEndObserver = nil }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; requested = false
        closeCurrent()
        if let dismissObserver { NotificationCenter.default.removeObserver(dismissObserver); self.dismissObserver = nil }
        // The originating SwiftUI update has finished before its binding is
        // reset. The controller remains alive only through this queued reset.
        let binding = binding, id = ownershipID, token = ownerToken
        DispatchQueue.main.async {
            guard FinderPopover.owns(id, token: token) else { return }
            if binding?.wrappedValue == true { binding?.wrappedValue = false }
            FinderPopover.release(id, token: token)
        }
        content = nil; self.binding = nil; anchor = nil
    }

    private static func root(_ content: AnyView, size: CGSize) -> AnyView {
        AnyView(content.frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped().transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true })
    }
    private static func validSize(_ size: CGSize) -> CGSize {
        .init(width: size.width.isFinite && size.width > 0 ? size.width : 400,
              height: size.height.isFinite && size.height > 0 ? size.height : 300)
    }
    private static func nativeEdge(_ edge: Edge) -> NSRectEdge {
        switch edge { case .top: return .maxY; case .bottom: return .minY; case .leading: return .minX; case .trailing: return .maxX }
    }
    deinit {
        if let dismissObserver { NotificationCenter.default.removeObserver(dismissObserver) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let sheetBeginObserver { NotificationCenter.default.removeObserver(sheetBeginObserver) }
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
    }
}
