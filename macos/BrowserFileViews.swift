import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Preserve each row's item identity and stripe index without allocating an
/// enumerated tuple array on every preview/progress update.
struct BrowserIndexedRows<Row: Identifiable>: RandomAccessCollection {
    struct Element: Identifiable {
        let index: Int
        let entry: Row
        var id: Row.ID { entry.id }
    }
    let rows: [Row]
    var startIndex: Int { rows.startIndex }
    var endIndex: Int { rows.endIndex }
    func index(after index: Int) -> Int { index + 1 }
    func index(before index: Int) -> Int { index - 1 }
    subscript(index: Int) -> Element { .init(index: index, entry: rows[index]) }
}

struct BrowserKeyboardMonitor: NSViewRepresentable {
    var handlesRangeSelection: Bool
    var handlesDelete: Bool
    var handlesZoom: Bool
    var handlesQuickLook: Bool
    let onShiftMove: (MoveCommandDirection) -> Void
    let onCommandDelete: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onActualSize: () -> Void
    /// Returns `true` when Space was consumed, so an unhandled Space still
    /// reaches whatever the responder chain would normally do with it.
    let onQuickLook: (NSWindow?) -> Bool
    let onCancelQuickLook: () -> Bool
    let ownsQuickLookPanel: (NSWindow) -> Bool
    /// Command-A is only ours once the guards above have ruled out text
    /// editing; a rename field or the search bar keeps the system behaviour.
    var handlesSelectAll = false
    var onSelectAllFolders: () -> Void = {}
    /// Up/Down reach the file list through SwiftUI's own focus. They are only
    /// ours once the list has given focus away — to the preview pane, its
    /// player or its buttons — and a preview is on screen to step through.
    var handlesPreviewNavigation = false
    /// The same walk while a slider holds focus, when the list cannot also be the focused control.
    var handlesPreviewNavigationFromControls = false
    var onPreviewMove: (Int) -> Void = { _ in }
    var handlesOpen = false
    var onOpen: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitoredView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var parent: BrowserKeyboardMonitor
        weak var monitoredView: NSView?
        private var eventMonitor: Any?

        init(parent: BrowserKeyboardMonitor) {
            self.parent = parent
        }

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                if MediaPreviewKeyView.handle(event) { return nil }
                guard let self, let browserWindow = self.monitoredView?.window,
                      let eventWindow = event.window ?? NSApp.keyWindow else { return event }
                let isFileWindow = eventWindow === browserWindow
                let isPreviewPanel = self.parent.ownsQuickLookPanel(eventWindow)
                guard isFileWindow || isPreviewPanel else { return event }
                let responder = eventWindow.firstResponder
                let isTextInput = (responder as? NSTextView).map { $0.isEditable || isFileWindow }
                    ?? (responder is NSText || responder is NSTextField || responder is NSControl)
                if self.parent.handlesQuickLook || isPreviewPanel,
                   let action = FinderQuickLookKeyboard.action(keyCode: event.keyCode,
                       modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                       isFileWindow: isFileWindow, isOwnedPreviewPanel: isPreviewPanel,
                       hasSheet: eventWindow.isSheet || eventWindow.attachedSheet != nil,
                       isTextInput: isTextInput) {
                    switch action {
                    case .toggle: if self.parent.onQuickLook(browserWindow) { return nil }
                    case .cancel: if self.parent.onCancelQuickLook() { return nil }
                    case .consumeRepeat: return nil
                    case .previous, .next: break // The panel's controller moves the selection.
                    }
                }
                guard isFileWindow, !eventWindow.isSheet, eventWindow.attachedSheet == nil else { return event }
                // Native editing, including quick-open, owns text shortcuts.
                // A focused slider keeps only Left/Right and Home/End; Up/Down still walk the files.
                let focusedSlider = NSApp.keyWindow?.firstResponder is MediaSliderControl
                if NSApp.keyWindow?.firstResponder is NSText || (focusedSlider && PreviewKeyRouting.sliderOwns(keyCode: event.keyCode)) { return event }
                let modifiers = event.modifierFlags.intersection(
                    .deviceIndependentFlagsMask
                )

                if self.parent.handlesZoom,
                   modifiers.contains(.command),
                   !modifiers.contains(.control),
                   !modifiers.contains(.option) {
                    switch event.keyCode {
                    case 24, 69: // Main keyboard =/+ and numeric keypad +.
                        self.parent.onZoomIn()
                        return nil
                    case 27, 78: // Main keyboard -/_ and numeric keypad -.
                        self.parent.onZoomOut()
                        return nil
                    case 29, 82: // Main keyboard 0 and numeric keypad 0.
                        self.parent.onActualSize()
                        return nil
                    default:
                        break
                    }
                }

                if self.parent.handlesDelete,
                   modifiers.contains(.command),
                   !modifiers.contains(.control),
                   !modifiers.contains(.option),
                   (event.keyCode == 51 || event.keyCode == 117) {
                    self.parent.onCommandDelete()
                    return nil
                }

                if self.parent.handlesPreviewNavigation || (focusedSlider && self.parent.handlesPreviewNavigationFromControls),
                   event.keyCode == 126 || event.keyCode == 125,
                   modifiers.intersection([.command, .shift, .option, .control]).isEmpty {
                    self.parent.onPreviewMove(event.keyCode == 125 ? 1 : -1)
                    return nil
                }

                if self.parent.handlesOpen, !isTextInput,
                   (event.keyCode == 36 || event.keyCode == 76),
                   modifiers.intersection([.command, .shift, .option, .control]).isEmpty {
                    self.parent.onOpen()
                    return nil
                }

                if self.parent.handlesSelectAll,
                   event.charactersIgnoringModifiers?.lowercased() == "a",
                   modifiers.intersection([.command, .shift, .option, .control]) == .command {
                    self.parent.onSelectAllFolders()
                    return nil
                }

                guard
                    self.parent.handlesRangeSelection,
                    modifiers.contains(.shift),
                    !modifiers.contains(.command),
                    !modifiers.contains(.control),
                    !modifiers.contains(.option)
                else { return event }

                switch event.keyCode {
                case 126:
                    self.parent.onShiftMove(.up)
                    return nil
                case 125:
                    self.parent.onShiftMove(.down)
                    return nil
                default:
                    return event
                }
            }
        }

        func stop() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        deinit {
            stop()
        }
    }
}

enum BrowserTreeColumnLimits {
    static let name: ClosedRange<CGFloat> = 150...720
    static let size: ClosedRange<CGFloat> = 58...180
    static let kind: ClosedRange<CGFloat> = 72...280
    static let modified: ClosedRange<CGFloat> = 108...360

    static func range(for column: BrowserSortColumn) -> ClosedRange<CGFloat> {
        switch column {
        case .name: return name
        case .size: return size
        case .kind: return kind
        case .modified: return modified
        }
    }

    static func clamped(_ width: CGFloat, for column: BrowserSortColumn) -> CGFloat {
        let bounds = range(for: column)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }
}

/// One resolved set of column dimensions shared by the sticky header and
/// every outline row. Keeping one source of truth prevents the header from
/// drifting out of alignment when a column is resized or hidden.
struct BrowserTreeColumnLayout {
    var name: CGFloat
    let size: CGFloat
    let kind: CGFloat
    let modified: CGFloat
    let showsSize: Bool
    let showsKind: Bool
    let showsModified: Bool
    let scale: CGFloat
    let action: CGFloat
    var trailingFill: CGFloat = 0

    var separator: CGFloat { max(7, 10 * scale) }
    var horizontalPadding: CGFloat { max(6, 9 * scale) }
    var headerHeight: CGFloat { max(24, 28 * scale) }

    private var minimumTableWidth: CGFloat {
        var width = horizontalPadding * 2 + name + action
        if showsSize { width += separator + size }
        if showsKind { width += separator + kind }
        if showsModified { width += separator + modified }
        return width
    }

    var tableWidth: CGFloat { minimumTableWidth + trailingFill }

    init(
        name: Double,
        size: Double,
        kind: Double,
        modified: Double,
        showsSize: Bool,
        showsKind: Bool,
        showsModified: Bool,
        scale: CGFloat,
        actionWidth: CGFloat
    ) {
        self.scale = scale
        self.action = max(28, actionWidth * scale)
        self.name = BrowserTreeColumnLimits.clamped(CGFloat(name), for: .name) * scale
        self.size = BrowserTreeColumnLimits.clamped(CGFloat(size), for: .size) * scale
        self.kind = BrowserTreeColumnLimits.clamped(CGFloat(kind), for: .kind) * scale
        self.modified = BrowserTreeColumnLimits.clamped(CGFloat(modified), for: .modified) * scale
        self.showsSize = showsSize
        self.showsKind = showsKind
        self.showsModified = showsModified
    }

    func filling(width: CGFloat) -> BrowserTreeColumnLayout {
        var result = self
        result.trailingFill = max(width - minimumTableWidth, 0)
        return result
    }

    func unscaledWidth(for column: BrowserSortColumn) -> CGFloat {
        let width: CGFloat
        switch column {
        case .name: width = name
        case .size: width = size
        case .kind: width = kind
        case .modified: width = modified
        }
        return width / max(scale, 0.01)
    }
}

struct BrowserTreeHeader: View {
    @State private var hoveredColumn: BrowserSortColumn?

    let columns: BrowserTreeColumnLayout
    let sortColumn: BrowserSortColumn
    let sortDirection: BrowserSortDirection
    let onSort: (BrowserSortColumn) -> Void
    let onResize: (BrowserSortColumn, CGFloat) -> Void
    let onResizeEnded: (BrowserSortColumn, CGFloat) -> Void
    let onToggleVisibility: (BrowserSortColumn) -> Void
    let onResetColumns: () -> Void
    let actionTitle: String?

    private var scale: CGFloat {
        columns.scale
    }

    var body: some View {
        HStack(spacing: 0) {
            sortableHeader("Name", column: .name, alignment: .leading)
                .frame(width: columns.name, alignment: .leading)
            resizeHandle(for: .name)

            if columns.showsSize {
                sortableHeader("Size", column: .size, alignment: .trailing)
                    .frame(width: columns.size, alignment: .trailing)
                resizeHandle(for: .size)
            }

            if columns.showsKind {
                sortableHeader("Kind", column: .kind, alignment: .leading)
                    .frame(width: columns.kind, alignment: .leading)
                resizeHandle(for: .kind)
            }

            if columns.showsModified {
                sortableHeader("Date Modified", column: .modified, alignment: .leading)
                    .frame(width: columns.modified, alignment: .leading)
                resizeHandle(for: .modified)
            }

            Color.clear
                .frame(width: columns.trailingFill)

            actionHeader
        }
        .font(.system(size: max(9, 11 * scale), weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, columns.horizontalPadding)
        .frame(width: columns.tableWidth, height: columns.headerHeight, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File columns")
        .browserContextMenu {
            columnVisibilityMenu
        }
    }

    private func sortableHeader(
        _ title: String,
        column: BrowserSortColumn,
        alignment: Alignment
    ) -> some View {
        Button {
            onSort(column)
        } label: {
            HStack(spacing: 4 * scale) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                    .lineLimit(1)
                if sortColumn == column {
                    Image(systemName: sortDirection.systemImage)
                        .font(.system(size: 7 * scale, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if alignment != .trailing {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, max(3, 5 * scale))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background(
                hoveredColumn == column
                    ? Color.primary.opacity(0.055)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
        .onHover { isHovered in
            hoveredColumn = isHovered ? column : nil
        }
        .help(
            sortColumn == column
                ? "Sort by \(title), \(sortDirection == .ascending ? "descending" : "ascending")"
                : "Sort by \(title), ascending"
        )
        .accessibilityLabel("Sort by \(title)")
        .accessibilityValue(
            sortColumn == column
                ? "Sorted \(sortDirection.title)"
                : "Not sorted"
        )
    }

    private func resizeHandle(for column: BrowserSortColumn) -> some View {
        BrowserColumnResizeHandle(
            column: column,
            currentWidth: columns.unscaledWidth(for: column),
            scale: scale,
            width: columns.separator,
            onResize: onResize,
            onResizeEnded: onResizeEnded
        )
    }

    private var columnsMenu: some View {
        Menu {
            columnVisibilityMenu
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: max(9, 11 * scale), weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Choose visible columns")
        .accessibilityLabel("Choose visible columns")
    }

    private var actionHeader: some View {
        HStack(spacing: max(2, 4 * scale)) {
            if let actionTitle {
                Text(actionTitle)
                    .lineLimit(1)
            }
            columnsMenu
                .frame(width: max(22, 24 * scale))
        }
        .frame(width: columns.action, alignment: .trailing)
    }

    @ViewBuilder
    private var columnVisibilityMenu: some View {
        Text("Show Columns")
        columnToggle("Size", column: .size, isVisible: columns.showsSize)
        columnToggle("Kind", column: .kind, isVisible: columns.showsKind)
        columnToggle(
            "Date Modified",
            column: .modified,
            isVisible: columns.showsModified
        )
        Divider()
        Button("Reset Column Layout", action: onResetColumns)
    }

    private func columnToggle(
        _ title: String,
        column: BrowserSortColumn,
        isVisible: Bool
    ) -> some View {
        Button {
            onToggleVisibility(column)
        } label: {
            if isVisible {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct BrowserColumnResizeHandle: View {
    let column: BrowserSortColumn
    let currentWidth: CGFloat
    let scale: CGFloat
    let width: CGFloat
    let onResize: (BrowserSortColumn, CGFloat) -> Void
    let onResizeEnded: (BrowserSortColumn, CGFloat) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(
                    isHovered || dragStartWidth != nil
                        ? Color.accentColor.opacity(0.7)
                        : Color.primary.opacity(0.1)
                )
                .frame(width: isHovered || dragStartWidth != nil ? 2 : 1)
                .padding(.vertical, max(4, 6 * scale))
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .highPriorityGesture(
            // This divider moves while its column changes width. A stationary
            // coordinate space keeps that motion out of the drag translation.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? currentWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    onResize(column, start + value.translation.width / max(scale, 0.01))
                }
                .onEnded { value in
                    let start = dragStartWidth ?? currentWidth
                    let finalWidth = start
                        + value.translation.width / max(scale, 0.01)
                    onResizeEnded(column, finalWidth)
                    dragStartWidth = nil
                }
        )
        .onDisappear {
            if isHovered {
                NSCursor.arrow.set()
            }
        }
        .help("Drag to resize the \(column.title) column")
        .accessibilityLabel("Resize \(column.title) column")
    }
}

/// A shared URL is a permanent section header above its folder/file rows.
/// The leading tool disconnects only the local link session.
struct SharedLinkTreeRow: View {
    @State private var isRowHovered = false
    @State private var isDisconnectHovered = false

    let entry: SharedLinkEntry
    let zoomScale: CGFloat
    let columns: BrowserTreeColumnLayout
    let isSelected: Bool
    let usesAlternateBackground: Bool
    let measurement: FolderMeasurement?
    let isMeasuring: Bool
    let isQueued: Bool
    let canMeasure: Bool
    let canEditLink: Bool
    let canDisconnect: Bool
    let onSelect: () -> Void
    let onMeasure: () -> Void
    let onEditLink: () -> Void
    let onCopyLink: () -> Void
    let onRetry: () -> Void
    let onDisconnect: () -> Void

    private var scale: CGFloat {
        min(max(zoomScale, CGFloat(BrowserItemZoom.minimum)), CGFloat(BrowserItemZoom.maximum))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5 * scale) {
                linkStatus

                // Use the checkbox slot beside the link icon, preserving the
                // name alignment with the nested file/folder rows.
                FinderRowAction(title: "Remove link from this app (keeps cloud files)",
                                symbol: "xmark", tint: .red, enabled: canDisconnect,
                                side: max(18, 22 * scale), hintOnRight: true,
                                onHover: { isDisconnectHovered = $0 },
                                action: onDisconnect)
                    .accessibilityLabel("Disconnect shared link \(entry.url)")

                Button(action: onSelect) {
                    HStack(spacing: 5 * scale) {
                        Image(systemName: "link")
                            .font(.system(size: 14 * scale, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 19 * scale)

                        Text(entry.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.url)

                        if entry.savedItemCount > 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundStyle(.green)
                                .help("\(entry.savedItemCount.formatted()) item(s) saved to your PikPak")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHandCursor()
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
            }
            .frame(width: columns.name, alignment: .leading)
            .zIndex(isDisconnectHovered ? 1 : 0)

            if columns.showsSize {
                columnGap
                sizeCell
                    .frame(width: columns.size, alignment: .trailing)
            }

            if columns.showsKind {
                columnGap
                Text("Link")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: columns.kind, alignment: .leading)
            }

            if columns.showsModified {
                columnGap
                Text(Self.addedDateFormatter.string(from: entry.addedAt))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Added \(Self.addedDateFormatter.string(from: entry.addedAt))")
                    .frame(width: columns.modified, alignment: .leading)
            }

            Color.clear
                .frame(width: columns.trailingFill)

            Color.clear
                .frame(width: columns.action)
        }
        .font(.system(size: max(10, 12.5 * scale)))
        .padding(.horizontal, columns.horizontalPadding)
        .frame(width: columns.tableWidth, alignment: .leading)
        .frame(height: max(24, 29 * scale))
        .background(rowBackground.animation(.easeOut(duration: 0.1), value: isRowHovered))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.045))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isRowHovered = hovering
        }
        .browserContextMenu {
            Button(action: onEditLink) {
                BrowserContextMenuStyle.label("Edit Link…", systemImage: "pencil")
            }
            .disabled(!canEditLink)

            // Copies the public share URL only. Any access code stays in the
            // app's owner-only local state.
            Button(action: onCopyLink) {
                BrowserContextMenuStyle.label("Copy Link", systemImage: "doc.on.doc")
            }

            if case .failed = entry.state {
                Button(action: onRetry) {
                    BrowserContextMenuStyle.label("Retry Link", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive, action: onDisconnect) {
                BrowserContextMenuStyle.label("Disconnect Link", systemImage: "xmark.circle")
            }
            .disabled(!canDisconnect)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var linkStatus: some View {
        switch entry.state {
        case .loading:
            ProgressView().controlSize(.mini)
                .frame(width: max(20, 24 * scale))
                .accessibilityLabel("Loading shared link")
        case .ready:
            EmptyView()
        case .failed(let message):
            Button(action: onRetry) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10 * scale, weight: .semibold)).foregroundStyle(.red)
                    .frame(width: max(20, 24 * scale), height: max(20, 24 * scale))
            }
            .buttonStyle(.plain).pointingHandCursor()
            .help("Retry shared link: \(message)")
            .accessibilityLabel("Retry shared link: \(message)")
        }
    }

    @ViewBuilder
    private var sizeCell: some View {
        if isMeasuring {
            HStack(spacing: 5 * scale) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning…")
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .help("Calculating the complete shared-link size")
        } else if isQueued {
            Label("Queued…", systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("This link will be scanned after the current folder-size calculation")
        } else if let measurement {
            Text(formatBytes(measurement.totalBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(
                    "\(measurement.fileCount.formatted()) file(s), "
                        + "\(measurement.folderCount.formatted()) subfolder(s)"
                )
        } else if canMeasure {
            Button("Calculate", action: onMeasure)
                .buttonStyle(.link)
                .controlSize(.mini)
                .help("Recursively calculate this shared link's size")
        } else {
            Text("--")
                .foregroundStyle(.tertiary)
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        if isRowHovered && !isDisconnectHovered {
            return Color.accentColor.opacity(0.055)
        }
        return usesAlternateBackground ? Color.primary.opacity(0.018) : Color.clear
    }

    private var columnGap: some View {
        Color.clear
            .frame(width: columns.separator)
    }

    private static let addedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }
}

struct BrowserTreeRow: View {
    @State private var isRowHovered = false
    @State private var isDisclosureHovered = false
    @State private var isCheckboxHovered = false
    @State private var isActionHovered = false

    let item: BrowserItem
    let depth: Int
    let zoomScale: CGFloat
    let columns: BrowserTreeColumnLayout
    let isActive: Bool
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let hasMoreItems: Bool
    let isLoadedAndEmpty: Bool
    let loadError: String?
    let usesAlternateBackground: Bool
    let canDownload: Bool
    let folderMeasurement: FolderMeasurement?
    let isMeasuringSize: Bool
    let isMeasurementQueued: Bool
    let canMeasureSize: Bool
    let isSavedToPikPak: Bool
    let showsShareActions: Bool
    let isSavingToPikPak: Bool
    let canSaveToPikPak: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onActivate: () -> Void
    let onToggle: () -> Void
    let onLoadMore: () -> Void
    let onRetry: () -> Void
    let onMeasure: () -> Void
    let onSave: () -> Void
    let onDownload: () -> Void
    var kindOverride: String? = nil
    var sizeOverride: String? = nil
    var downloadHelp: String? = nil
    var iconContent: AnyView? = nil

    private var scale: CGFloat {
        min(max(zoomScale, CGFloat(BrowserItemZoom.minimum)), CGFloat(BrowserItemZoom.maximum))
    }

    var body: some View {
        #if BROWSER_SCROLL_PROFILING
        let _ = BrowserScrollDiagnostics.rowBodies += 1
        #endif
        HStack(spacing: 0) {
            HStack(spacing: 5 * scale) {
                Color.clear
                    .frame(width: CGFloat(depth) * 16 * scale)

                disclosure

                Button(action: onToggleSelection) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                isCheckboxHovered
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear
                            )
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14 * scale, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: max(18, 22 * scale), height: max(18, 22 * scale))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHandCursor()
                .onHover { isCheckboxHovered = $0 }
                .help(
                    isSelected
                        ? "Deselect this selection (folders include all contents)"
                        : "Add to selection (folders include all contents)"
                )
                .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")

                selectableCell(
                    HStack(spacing: 5 * scale) {
                        Group {
                            if let iconContent { iconContent }
                            else { Image(systemName: symbol).font(.system(size: 14 * scale, weight: .medium)).foregroundStyle(symbolColor) }
                        }.frame(width: 19 * scale, height: 19 * scale)

                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.name)

                        if isLoadedAndEmpty && isExpanded {
                            Text("Empty")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5 * scale)
                                .padding(.vertical, 2 * scale)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                )

                if let loadError {
                    Button(action: onRetry) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless).pointingHandCursor()
                    .help("\(loadError) Click to retry.")
                    .accessibilityLabel("Retry loading \(item.name)")
                } else if hasMoreItems && isExpanded && !isLoading {
                    Button("More…", action: onLoadMore)
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .help("Load more items from \(item.name)")
                }
            }
            .frame(width: columns.name, alignment: .leading)
            .clipped()

            if columns.showsSize {
                columnGap
                folderSizeCell
                    .frame(width: columns.size, alignment: .trailing)
            }

            if columns.showsKind {
                columnGap
                selectableCell(
                    Text(kindTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(kindTitle)
                        .frame(width: columns.kind, alignment: .leading)
                )
            }

            if columns.showsModified {
                columnGap
                selectableCell(
                    Text(modifiedTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(modifiedTitle)
                        .frame(width: columns.modified, alignment: .leading)
                )
            }

            Color.clear
                .frame(width: columns.trailingFill)

            HStack(spacing: 4 * scale) {
                if showsShareActions {
                    FinderRowAction(title: isSavedToPikPak ? "Saved to My PikPak" : (isSavingToPikPak ? "Saving to My PikPak…" : "Save to My PikPak"),
                        symbol: isSavedToPikPak ? "checkmark.circle.fill" : "icloud.and.arrow.up",
                        tint: isSavedToPikPak ? .green : .accentColor,
                        busy: isSavingToPikPak, enabled: canSaveToPikPak && !isSavedToPikPak,
                        side: max(21, 24 * scale), onHover: { isActionHovered = $0 }, action: onSave)
                }
                FinderRowAction(title: downloadHelp ?? "Add \(item.isFolder ? "folder" : "file") to download queue",
                    symbol: "arrow.down.circle", enabled: canDownload,
                    side: max(21, 24 * scale), onHover: { isActionHovered = $0 }, action: onDownload)
            }
            .frame(width: columns.action)
        }
        .font(.system(size: max(10, 12.5 * scale)))
        .padding(.horizontal, columns.horizontalPadding)
        .frame(width: columns.tableWidth, alignment: .leading)
        .frame(height: max(24, 29 * scale))
        // Animate the highlight only, not the row's inherited font or its
        // context-menu symbols when macOS opens/closes the menu.
        .background(rowBackground.animation(.easeOut(duration: 0.1), value: isRowHovered))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.045))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isRowHovered = hovering
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var folderSizeCell: some View {
        if let sizeOverride {
            selectableCell(Text(sizeOverride).monospacedDigit().foregroundStyle(.secondary).lineLimit(1))
        } else if !item.isFolder {
            selectableCell(
                Text(formatBytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            )
        } else if isMeasuringSize {
            HStack(spacing: 5 * scale) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning…")
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .help("Scanning this folder and all subfolders")
        } else if isMeasurementQueued {
            Label("Queued…", systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("This folder will be scanned after the current size calculation")
        } else if let folderMeasurement {
            selectableCell(
                Text(formatBytes(folderMeasurement.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(
                        "\(folderMeasurement.fileCount.formatted()) file(s), "
                            + "\(folderMeasurement.folderCount.formatted()) subfolder(s)"
                    )
            )
        } else {
            Button(action: onMeasure) {
                Text("Calculate")
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .controlSize(.mini)
            .disabled(!canMeasureSize)
            .help("Recursively calculate this folder's size")
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if item.isFolder {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isDisclosureHovered
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10 * scale, weight: .bold))
                            .foregroundStyle(
                                isDisclosureHovered ? Color.accentColor : Color.secondary
                            )
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.12), value: isExpanded)
                    }
                }
                .frame(width: max(20, 24 * scale), height: max(20, 24 * scale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .scaleEffect(isDisclosureHovered ? 1.06 : 1)
            .animation(.easeOut(duration: 0.1), value: isDisclosureHovered)
            .onHover { isDisclosureHovered = $0 }
            .help(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
            .accessibilityLabel(isExpanded ? "Collapse \(item.name)" : "Expand \(item.name)")
        } else {
            Color.clear
                .frame(width: max(20, 24 * scale), height: max(20, 24 * scale))
        }
    }

    private func selectableCell<Content: View>(_ content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onActivate()
                    }
            )
    }

    private var symbol: String {
        if item.isFolder { return "folder.fill" }
        if item.isTextPreviewable { return "doc.plaintext" }
        switch item.mediaKind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .other: return "doc"
        }
    }

    private var symbolColor: Color {
        if item.isFolder { return .blue }
        if item.isTextPreviewable { return .indigo }
        switch item.mediaKind {
        case .image: return .teal
        case .video: return .purple
        case .audio: return .orange
        case .other: return .secondary
        }
    }

    private var kindTitle: String {
        kindOverride ?? item.kindDisplayTitle
    }

    private var modifiedTitle: String {
        guard let modifiedTime = item.modifiedTime, !modifiedTime.isEmpty else { return "--" }
        return Self.displayDate(from: modifiedTime) ?? modifiedTime
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(isActive ? 0.2 : 0.13)
        }
        if isActive {
            return Color.accentColor.opacity(0.08)
        }
        if isRowHovered && !isActionHovered {
            return Color.accentColor.opacity(0.055)
        }
        return usesAlternateBackground ? Color.primary.opacity(0.018) : Color.clear
    }

    private var columnGap: some View {
        Color.clear
            .frame(width: columns.separator)
    }

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISOFormatter = ISO8601DateFormatter()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func displayDate(from value: String) -> String? {
        let date = fractionalISOFormatter.date(from: value) ?? basicISOFormatter.date(from: value)
        return date.map(displayDateFormatter.string(from:))
    }

    private func formatBytes(_ size: UInt64) -> String {
        let bounded = Int64(min(size, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: bounded, countStyle: .binary)
    }
}

struct BrowserThumbnailTile: View {
    @State private var isHovered = false
    @State private var isCheckboxHovered = false

    let item: BrowserItem
    let scale: CGFloat
    let sizeLabel: String
    let systemImage: String
    let isActive: Bool
    let isSelected: Bool
    let isMeasuringSize: Bool
    let isMeasurementQueued: Bool
    let isSavedToPikPak: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onActivate: () -> Void
    var thumbnailContent: AnyView? = nil
    var thumbnailProxyURL: String = ""
    var thumbnailCache: ThumbnailCache? = nil

    private var thumbnailSide: CGFloat { 82 * scale }

    var body: some View {
        VStack(spacing: max(5, 7 * scale)) {
            thumbnail
                .frame(width: thumbnailSide, height: thumbnailSide)

            Text(item.name)
                .font(.system(size: max(10, 12 * scale), weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: max(25, 30 * scale), alignment: .top)
                .help(item.name)

            if isMeasuringSize {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Scanning…")
                }
                .font(.system(size: max(8.5, 10 * scale)))
                .foregroundStyle(.secondary)
            } else if isMeasurementQueued {
                Label("Queued…", systemImage: "clock")
                    .font(.system(size: max(8.5, 10 * scale)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(sizeLabel)
                    .font(.system(size: max(8.5, 10 * scale)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, max(5, 7 * scale))
        .padding(.vertical, max(7, 9 * scale))
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 11 * scale)
                .fill(tileBackground)
                .animation(.easeOut(duration: 0.1), value: isHovered)
        }
        // Attach the tile gesture before adding the checkbox overlay. This
        // keeps a checkbox click from also firing the tile's row-selection
        // gesture, whose order was nondeterministic in SwiftUI.
        .contentShape(RoundedRectangle(cornerRadius: 11 * scale))
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    onActivate()
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11 * scale)
                .strokeBorder(tileBorder, lineWidth: isActive ? 2 : 1)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onToggleSelection) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            isCheckboxHovered
                                ? Color.accentColor.opacity(0.14)
                                : Color(nsColor: .windowBackgroundColor).opacity(0.88)
                        )
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15 * scale, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .frame(width: max(22, 25 * scale), height: max(22, 25 * scale))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHandCursor()
            .onHover { isCheckboxHovered = $0 }
            .help(
                isSelected
                    ? "Deselect this selection (folders include all contents)"
                    : "Add to selection (folders include all contents)"
            )
            .accessibilityLabel(isSelected ? "Deselect \(item.name)" : "Select \(item.name)")
            .padding(max(3, 4 * scale))
        }
        .overlay(alignment: .topTrailing) {
            if isSavedToPikPak {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(.white, .green)
                    .padding(max(5, 6 * scale))
                .help("Saved to your PikPak in this app session")
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(sizeLabel)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if item.isFolder {
            ZStack {
                RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                    .fill(Color.blue.opacity(isSelected ? 0.12 : 0.06))
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.62, blue: 1), .blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(10 * scale)
                    .shadow(color: .blue.opacity(0.18), radius: 3 * scale, y: 2 * scale)
            }
        } else if let thumbnailContent { thumbnailContent }
        else {
            RemoteArtwork(
                url: item.artworkURL,
                systemName: systemImage,
                fit: item.mediaKind == .audio || item.mediaKind == .other,
                proxyURL: thumbnailProxyURL,
                cache: thumbnailCache
            )
            .frame(width: thumbnailSide, height: thumbnailSide)
            .background(Color.secondary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.mediaKind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6 * scale)
                        .background(.black.opacity(0.58), in: Circle())
                        .padding(5 * scale)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 3 * scale, y: 2 * scale)
        }
    }

    private var tileBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(isActive ? 0.16 : 0.1)
        }
        if isHovered {
            return Color.primary.opacity(0.045)
        }
        return .clear
    }

    private var tileBorder: Color {
        if isActive {
            return Color.accentColor.opacity(0.75)
        }
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        return Color.clear
    }
}

struct RemoteArtwork: View {
    let url: URL?
    let systemName: String
    let fit: Bool
    var proxyURL: String = ""
    var cache: ThumbnailCache? = nil
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var loadedKey: ThumbnailCache.Key?

    private var requestKey: ThumbnailCache.Key? {
        url.map { ThumbnailCache.Key(url: $0, proxy: PreviewTransport.effectiveProxyURL(proxyURL)) }
    }

    var body: some View {
        ZStack {
            if let image, loadedKey == requestKey {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                placeholder.overlay { if isLoading { ProgressView().controlSize(.small) } }
            }
        }
        .task(id: requestKey) {
            image = nil
            loadedKey = requestKey
            guard let key = requestKey else { isLoading = false; return }
            isLoading = true
            let result = try? await (cache ?? ThumbnailCache.shared).image(at: key.url, proxyURL: key.proxy)
            guard !Task.isCancelled else { return }
            image = result
            isLoading = false
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }
}

/// Adds two representations to one Finder-style drag: an own-process token for
/// moving items between PikPak folders and a lazy file promise for downloading
/// the same selection when it is dropped into Finder. Credentials and remote
/// URLs never enter the pasteboard.
struct BrowserMoveDragSourceModifier: ViewModifier {
    @ObservedObject var model: DownloaderModel
    let item: BrowserItem

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.canBeginBrowserDrag {
            content
                .contentShape(Rectangle())
                .onDrag {
                    guard let token = model.beginBrowserDrag(item) else {
                        return NSItemProvider()
                    }
                    let provider: NSItemProvider
                    if let promiseProvider = model.makeBrowserDownloadPromiseProvider() {
                        provider = promiseProvider
                    } else {
                        provider = NSItemProvider()
                        provider.suggestedName = model.browserDragTitle(startingWith: item)
                    }
                    provider.registerDataRepresentation(
                        forTypeIdentifier: UTType.pikPakBrowserItems.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(Data(token.utf8), nil)
                        return nil
                    }
                    return provider
                } preview: {
                    // SwiftUI builds this closure with every row render. Summarize
                    // the selection only when a drag actually draws the preview.
                    BrowserMoveDragPreviewSource(model: model, item: item)
                }
        } else {
            content
        }
    }
}

struct BrowserMoveDragPreviewSource: View {
    let model: DownloaderModel
    let item: BrowserItem

    var body: some View {
        BrowserMoveDragPreview(
            title: model.browserDragTitle(startingWith: item),
            itemCount: model.browserDragItemCount(startingWith: item),
            containsFolder: model.browserDragContainsFolder(startingWith: item)
        )
    }
}

/// A compact Finder-like stack makes it explicit that dragging one checked
/// row carries the complete multi-selection rather than only the row under the
/// pointer.
struct BrowserMoveDragPreview: View {
    let title: String
    let itemCount: Int
    let containsFolder: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: containsFolder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                if itemCount > 1 {
                    Text(itemCount.formatted())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 10, y: -7)
                }
            }
            .frame(width: 36, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    itemCount == 1
                        ? "Move in PikPak or download to Finder"
                        : "Move selection or download it to Finder"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }
}

extension View {
    func browserMoveDragSource(model: DownloaderModel, item: BrowserItem) -> some View {
        modifier(BrowserMoveDragSourceModifier(model: model, item: item))
    }

    func appCard(padding: CGFloat) -> some View { finderCard(padding: padding) }
}
