import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pikPakBrowserItems = UTType(exportedAs: "com.wky.pikpakdownloader.browser-items")
}

enum BrowserDropPayload: Equatable {
    case move
    case upload

    /// A cloud drag also offers a lazy Finder download representation. Never
    /// load it as an upload, even if the current move target is invalid.
    static func classify(hasCloudItems: Bool, hasFileURLs: Bool) -> Self? {
        if hasCloudItems { return .move }
        return hasFileURLs ? .upload : nil
    }
}

struct BrowserDropZone: Equatable {
    let id: String
    let destination: BrowserLocation?
    let isFolder: Bool
    let frame: CGRect
    let cornerRadius: CGFloat
}

struct BrowserDropTarget: Equatable {
    let destination: BrowserLocation?
    let highlightFrame: CGRect?
    let cornerRadius: CGFloat
    let springFolderID: String?
}

enum BrowserDropTargetResolver {
    static func resolve(at point: CGPoint, zones: [String: BrowserDropZone],
                        bounds: CGRect, current: BrowserLocation) -> BrowserDropTarget? {
        guard bounds.contains(point) else { return nil }
        // Geometry is resolved relative to the single drop canvas, so scrolling,
        // row indentation, column resizing and thumbnail zoom use the same hit
        // test as the highlight. An invalid folder never falls through to root.
        let hit = zones.values.filter { $0.frame.intersection(bounds).contains(point) }
            .min { lhs, rhs in
                let a = lhs.frame.width * lhs.frame.height, b = rhs.frame.width * rhs.frame.height
                return a == b ? lhs.id < rhs.id : a < b
            }
        guard let hit else {
            return BrowserDropTarget(destination: current, highlightFrame: nil,
                                     cornerRadius: 10, springFolderID: nil)
        }
        let parentZone = hit.destination.flatMap { zones[$0.id] }
        let highlighted = hit.isFolder ? hit : (parentZone?.isFolder == true ? parentZone : nil)
        let clipped = highlighted?.frame.intersection(bounds)
        // Lazy stacks may retain an off-screen parent's anchor. CGRect.null
        // has infinite coordinates and must never become a SwiftUI position.
        let visibleFrame = clipped.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
        return BrowserDropTarget(destination: hit.destination,
                                 highlightFrame: visibleFrame,
                                 cornerRadius: highlighted?.cornerRadius ?? 10,
                                 springFolderID: hit.isFolder ? hit.id : nil)
    }
}

struct BrowserDropHover: Equatable {
    let target: BrowserDropTarget
    let payload: BrowserDropPayload
    let count: Int
    let rejection: String?
    var isAllowed: Bool { rejection == nil && target.destination != nil }
}

/// Only this small subtree observes pointer feedback. Scrolling does not
/// publish geometry changes through the large DownloaderModel/browser tree.
@MainActor
final class BrowserDropCoordinator: ObservableObject {
    @Published private(set) var hover: BrowserDropHover?
    @Published private(set) var isTracking = false
    private(set) var geometryIsReady = false
    private(set) var zones: [String: BrowserDropZone] = [:]
    private var bounds = CGRect.zero
    private var lastPoint: CGPoint?
    private var current: BrowserLocation?
    private var payload: BrowserDropPayload?
    private var count = 0
    private var validate: ((BrowserLocation, BrowserDropPayload) -> String?)?
    private var expand: ((String) -> Void)?
    private var springTask: Task<Void, Never>?
    private var springFolderID: String?

    func beginTracking() {
        guard !isTracking else { return }
        clear()
        bounds = .zero
        isTracking = true
    }

    func setGeometry(zones: [String: BrowserDropZone], bounds: CGRect) {
        self.zones = zones
        self.bounds = bounds
        geometryIsReady = true
        refresh()
    }

    @discardableResult
    func update(point: CGPoint, current: BrowserLocation, payload: BrowserDropPayload,
                count: Int, validate: @escaping (BrowserLocation, BrowserDropPayload) -> String?,
                expand: ((String) -> Void)?) -> BrowserDropHover? {
        lastPoint = point
        self.current = current
        self.payload = payload
        self.count = count
        self.validate = validate
        self.expand = expand
        refresh()
        return hover
    }

    func clear() {
        springTask?.cancel(); springTask = nil; springFolderID = nil
        lastPoint = nil; current = nil; payload = nil; validate = nil; expand = nil
        if hover != nil { hover = nil }
        geometryIsReady = false
        zones = [:]
        if isTracking { isTracking = false }
    }

    private func refresh() {
        guard geometryIsReady else { return }
        guard let point = lastPoint, let current, let payload else { return }
        guard let target = BrowserDropTargetResolver.resolve(at: point, zones: zones, bounds: bounds, current: current) else {
            clear()
            return
        }
        let rejection: String?
        if let destination = target.destination {
            rejection = validate?(destination, payload)
        } else {
            rejection = "This item's parent folder is not available. Drop onto a folder or the blank area instead."
        }
        let next = BrowserDropHover(target: target, payload: payload, count: count, rejection: rejection)
        if hover != next { hover = next }
        let springID = next.isAllowed && expand != nil ? target.springFolderID : nil
        if springID != springFolderID {
            springTask?.cancel()
            springFolderID = springID
            if let springID {
                springTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, let self, self.springFolderID == springID,
                          self.hover?.isAllowed == true else { return }
                    self.expand?(springID)
                }
            }
        }
    }
}

private struct BrowserDropRegion {
    let id: String
    let destination: BrowserLocation?
    let isFolder: Bool
    let cornerRadius: CGFloat
    let anchor: Anchor<CGRect>
}

private struct BrowserDropRegionsKey: PreferenceKey {
    static var defaultValue: [String: BrowserDropRegion] = [:]
    static func reduce(value: inout [String: BrowserDropRegion], nextValue: () -> [String: BrowserDropRegion]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct BrowserDropTrackingKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var tracksBrowserDropGeometry: Bool {
        get { self[BrowserDropTrackingKey.self] }
        set { self[BrowserDropTrackingKey.self] = newValue }
    }
}

private struct BrowserDropRegionModifier: ViewModifier {
    @Environment(\.tracksBrowserDropGeometry) private var isTracking
    let id: String
    let destination: BrowserLocation?
    let isFolder: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        // Keep row identity and the drag source stable when tracking starts.
        content.anchorPreference(key: BrowserDropRegionsKey.self, value: .bounds) {
            isTracking ? [id: BrowserDropRegion(id: id, destination: destination,
                isFolder: isFolder, cornerRadius: cornerRadius, anchor: $0)] : [:]
        }
    }
}

private struct BrowserDropCanvasModifier: ViewModifier {
    @ObservedObject var model: DownloaderModel
    let destination: BrowserLocation?
    let springLoadsFolders: Bool
    let compact: Bool
    let onUploadStarted: () -> Void
    @StateObject private var coordinator = BrowserDropCoordinator()

    @ViewBuilder
    func body(content: Content) -> some View {
        if let destination, !model.isBrowsingSharedLink {
            content
                .environment(\.tracksBrowserDropGeometry, coordinator.isTracking)
                .backgroundPreferenceValue(BrowserDropRegionsKey.self) { regions in
                    if coordinator.isTracking {
                        GeometryReader { geometry in
                            #if BROWSER_SCROLL_PROFILING
                            let _ = BrowserScrollDiagnostics.resolveGeometry(regions.count)
                            #endif
                            let zones = regions.mapValues { region in
                                BrowserDropZone(id: region.id, destination: region.destination,
                                                isFolder: region.isFolder, frame: geometry[region.anchor],
                                                cornerRadius: region.cornerRadius)
                            }
                            Color.clear
                                .onAppear { coordinator.setGeometry(zones: zones, bounds: CGRect(origin: .zero, size: geometry.size)) }
                                .onChange(of: zones) { coordinator.setGeometry(zones: $0, bounds: CGRect(origin: .zero, size: geometry.size)) }
                                .onChange(of: geometry.size) { coordinator.setGeometry(zones: zones, bounds: CGRect(origin: .zero, size: $0)) }
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Exactly one receiver, for both kinds of payload. Rows only
                // contribute bounds; they cannot compete with this receiver.
                .onDrop(of: [UTType.pikPakBrowserItems.identifier, UTType.fileURL.identifier],
                        delegate: BrowserDropDelegate(model: model, current: destination,
                            coordinator: coordinator, springLoadsFolders: springLoadsFolders,
                            onUploadStarted: onUploadStarted))
                .overlay { BrowserDropFeedback(coordinator: coordinator, compact: compact).allowsHitTesting(false) }
                .background {
                    BrowserDropEscapeMonitor {
                        coordinator.clear()
                        model.cancelBrowserDrag()
                    }.frame(width: 0, height: 0)
                }
                .onDisappear { coordinator.clear() }
        } else {
            content
        }
    }
}

struct BrowserDropDelegate: DropDelegate {
    let model: DownloaderModel
    let current: BrowserLocation
    let coordinator: BrowserDropCoordinator
    let springLoadsFolders: Bool
    let onUploadStarted: () -> Void

    private func payload(_ info: DropInfo) -> BrowserDropPayload? {
        BrowserDropPayload.classify(
            hasCloudItems: info.hasItemsConforming(to: [UTType.pikPakBrowserItems.identifier]),
            hasFileURLs: info.hasItemsConforming(to: [UTType.fileURL.identifier]))
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard !model.isBrowsingSharedLink, payload(info) != nil else { return false }
        coordinator.beginTracking()
        return true
    }

    private func update(at point: CGPoint, payload: BrowserDropPayload?) -> BrowserDropHover? {
        guard let payload else { coordinator.clear(); return nil }
        coordinator.beginTracking()
        // DropInfo.itemProviders is only valid inside performDrop. Finder's
        // item count is unknown during hover; never request its providers just
        // to populate feedback before macOS grants access to the payload.
        return coordinator.update(point: point, current: current, payload: payload,
            count: payload == .move ? model.activeBrowserDragItemCount : 0,
            validate: { model.browserDropRejection(on: $0, payload: $1) },
            expand: springLoadsFolders ? { model.springExpandBrowserDropFolder($0) } : nil)
    }

    func dropEntered(info: DropInfo) { _ = update(at: info.location, payload: payload(info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        proposal(at: info.location, payload: payload(info))
    }

    func proposal(at point: CGPoint, payload: BrowserDropPayload?) -> DropProposal {
        guard let payload else { coordinator.clear(); return DropProposal(operation: .cancel) }
        let hover = update(at: point, payload: payload)
        // Geometry arrives in the next layout pass. Cancelling here can leave
        // macOS with a cancelled proposal even after that pass displays an
        // allowed target, if the pointer stays still until release. Keep the
        // offer alive, then require a resolved, valid destination on release.
        if let hover, !hover.isAllowed { return DropProposal(operation: .cancel) }
        return DropProposal(operation: payload == .move ? .move : .copy)
    }
    func dropExited(info: DropInfo) { coordinator.clear() }

    func performDrop(info: DropInfo) -> Bool {
        receive(at: info.location, payload: payload(info)) { payload in
            info.itemProviders(for: [payload == .move ? UTType.pikPakBrowserItems.identifier : UTType.fileURL.identifier])
        }
    }

    /// The provider closure is invoked synchronously, only at release. Loading
    /// also starts before performDrop returns; only its completion is async.
    @discardableResult
    func receive(at point: CGPoint, payload: BrowserDropPayload?,
                 providers: (BrowserDropPayload) -> [NSItemProvider]) -> Bool {
        defer { coordinator.clear() }
        guard let payload else {
            model.reportBrowserDropFailure("This drop does not contain local files or PikPak items.")
            return false
        }
        guard let hover = update(at: point, payload: payload) else {
            model.reportBrowserDropFailure("The destination is not ready. Drop the files onto the folder again.")
            return false
        }
        guard hover.isAllowed, let destination = hover.target.destination else {
            model.reportBrowserDropFailure(hover.rejection ?? "This folder cannot accept the dropped items.")
            return false
        }
        // Capture the permitted payload and start reading it before clearing
        // hover/layout state. Never redirect an unresolved target to root.
        let offeredProviders = providers(payload)
        switch hover.payload {
        case .move:
            guard let provider = offeredProviders.first else {
                model.reportBrowserDropFailure("The drag session no longer contains PikPak items. Drag the selection again.")
                return false
            }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pikPakBrowserItems.identifier) { data, error in
                DispatchQueue.main.async {
                    guard error == nil, let data, let token = String(data: data, encoding: .utf8),
                          model.performBrowserDrop(token: token, on: destination) else {
                        model.reportBrowserDropFailure("The drag session expired or this move is no longer valid. Drag the selection again.")
                        return
                    }
                }
            }
        case .upload:
            guard !offeredProviders.isEmpty else {
                model.reportBrowserDropFailure("Finder did not supply any local files. Drag the files or folders again.")
                return false
            }
            guard let accountID = model.browserDropAccountID else {
                model.reportBrowserDropFailure("The account is not ready for uploads. Check your account in Settings, then try again.")
                return false
            }
            model.reportBrowserUploadPreparation(count: offeredProviders.count, destination: destination)
            LocalUploadFileURLLoader.loadResult(offeredProviders) { result in
                switch result {
                case .success(let urls):
                    if model.uploadDroppedLocalItems(urls, to: destination, expectedAccountID: accountID) {
                        onUploadStarted()
                    }
                case .failure(let error):
                    model.reportBrowserDropFailure(error)
                }
            }
        }
        return true
    }
}

private struct BrowserDropFeedback: View {
    @ObservedObject var coordinator: BrowserDropCoordinator
    let compact: Bool

    var body: some View {
        if let hover = coordinator.hover {
            GeometryReader { geometry in
                let color = hover.isAllowed ? Color.accentColor : Color.red
                let frame = hover.target.highlightFrame ?? CGRect(origin: .zero, size: geometry.size)
                RoundedRectangle(cornerRadius: hover.target.cornerRadius)
                    .fill(color.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: hover.target.cornerRadius).strokeBorder(color, lineWidth: 2) }
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)

                if !compact {
                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 9) {
                            Image(systemName: !hover.isAllowed ? "nosign" : (hover.payload == .upload ? "plus.circle.fill" : "arrow.right.circle.fill"))
                                .font(.title2)
                                .foregroundStyle(color)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hover.rejection ?? "\(hover.payload == .upload ? "Upload" : "Move") \(hover.count > 0 ? "\(hover.count.formatted()) item(s)" : "items") to \(hover.target.destination?.name ?? "folder")")
                                    .font(.callout.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let destination = hover.target.destination {
                                    Text("PikPak\(destination.path == "/" ? " /" : destination.path)")
                                        .font(.caption).lineLimit(2).truncationMode(.middle)
                                }
                                if hover.isAllowed && hover.payload == .upload {
                                    Text("Copies from Finder; originals stay on your Mac. Release to upload and open Transfers.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.4)) }
                        .padding(10)
                    }
                }
            }
            .clipped()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(hover.rejection ?? "\(hover.payload == .upload ? "Upload" : "Move") to \(hover.target.destination?.path ?? "/")")
        }
    }
}

private struct BrowserDropEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void
    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.onEscape = onEscape }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53, event.window === self?.window { self?.onEscape?() }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { stop() }
    }
}

extension View {
    @ViewBuilder
    func browserDropRegion(id: String, destination: BrowserLocation?, isFolder: Bool,
                           cornerRadius: CGFloat = 5) -> some View {
        #if BROWSER_SCROLL_PROFILING
        if BrowserScrollDiagnostics.disableDropGeometry { self }
        else {
            modifier(BrowserDropRegionModifier(id: id, destination: destination, isFolder: isFolder, cornerRadius: cornerRadius))
        }
        #else
        modifier(BrowserDropRegionModifier(id: id, destination: destination, isFolder: isFolder, cornerRadius: cornerRadius))
        #endif
    }

    func browserDropCanvas(model: DownloaderModel, destination: BrowserLocation?,
                           springLoadsFolders: Bool = false, compact: Bool = false,
                           onUploadStarted: @escaping () -> Void) -> some View {
        modifier(BrowserDropCanvasModifier(model: model, destination: destination,
            springLoadsFolders: springLoadsFolders, compact: compact, onUploadStarted: onUploadStarted))
    }
}
