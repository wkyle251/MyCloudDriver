import AppKit
import SwiftUI

/// Use the same column header and rows as PikPak, with native provider actions.
/// Expanded rows retain their occurrence identity; no media is decoded here.
struct NativeDriveFileList<Context: View, Empty: View>: View {
    @ObservedObject var model: NativeDriveModel
    var resetRevision = 0
    @ViewBuilder var menu: ([CloudDriveItem]) -> Context
    @ViewBuilder var empty: () -> Empty
    @AppStorage("browserNameColumnWidth") private var nameWidth = 250.0
    @AppStorage("browserSizeColumnWidth") private var sizeWidth = 76.0
    @AppStorage("browserKindColumnWidth") private var kindWidth = 104.0
    @AppStorage("browserModifiedColumnWidth") private var dateWidth = 156.0
    @AppStorage("browserShowsSizeColumn") private var showsSize = true
    @AppStorage("browserShowsKindColumn") private var showsKind = true
    @AppStorage("browserShowsModifiedColumn") private var showsDate = true
    @State private var liveWidths: [BrowserSortColumn: Double] = [:]

    var body: some View {
        let selected = model.selectedItems
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                let columns = BrowserTreeColumnLayout(name: liveWidths[.name] ?? nameWidth,
                    size: liveWidths[.size] ?? sizeWidth, kind: liveWidths[.kind] ?? kindWidth,
                    modified: liveWidths[.modified] ?? dateWidth, showsSize: showsSize, showsKind: showsKind,
                    showsModified: showsDate, scale: model.zoom, actionWidth: 32).filling(width: viewport.size.width)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        BrowserTreeHeader(columns: columns, sortColumn: model.browserSortColumn,
                            sortDirection: model.browserSortDirection, onSort: model.toggleSort,
                            onResize: { column, width in liveWidths[column] = Double(BrowserTreeColumnLimits.clamped(width, for: column)) },
                            onResizeEnded: saveWidth, onToggleVisibility: toggleColumn, onResetColumns: resetColumns,
                            actionTitle: nil)
                        Divider()
                        if model.visibleRows.isEmpty {
                            empty().frame(maxWidth: .infinity, maxHeight: .infinity).browserContextMenu { menu([]) }
                        }
                        else {
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(model.visibleRows.enumerated()), id: \.element.id) { index, entry in
                                        row(entry, index: index, columns: columns)
                                            .id(entry.id)
                                            .browserContextMenu { menu(model.selection.contains(entry.item.id) ? selected : [entry.item]) }
                                    }
                                }.frame(minHeight: max(0, viewport.size.height - columns.headerHeight - 1), alignment: .top)
                                    .background(Color(nsColor: .controlBackgroundColor).onTapGesture { model.selection = [] }.browserContextMenu { menu([]) })
                            }
                        }
                    }.frame(width: columns.tableWidth, height: viewport.size.height)
                }
            }.onChange(of: model.focusedRowID) { id in
                if let id { proxy.scrollTo(id) }
            }
        }.accessibilityLabel("Cloud files")
            .onChange(of: resetRevision) { _ in liveWidths = [:] }
    }
    private func row(_ entry: NativeDriveRow, index: Int, columns: BrowserTreeColumnLayout) -> some View {
        let item = entry.item, branch = model.tree.branch(for: entry.item)
        return BrowserTreeRow(item: item.browserItem, depth: entry.depth, zoomScale: model.zoom, columns: columns,
            isActive: model.selection.contains(item.id), isSelected: model.selection.contains(item.id),
            isExpanded: model.tree.expanded.contains(entry.id), isLoading: branch.isLoading,
            hasMoreItems: branch.nextOffset != nil, isLoadedAndEmpty: branch.loaded && branch.items.isEmpty, loadError: branch.error,
            usesAlternateBackground: index.isMultiple(of: 2), canDownload: model.isConnected,
            folderMeasurement: nil, isMeasuringSize: false, isMeasurementQueued: false, canMeasureSize: model.isConnected,
            isSavedToPikPak: false, showsShareActions: false, isSavingToPikPak: false, canSaveToPikPak: false,
            onSelect: { model.select(entry, extending: NSEvent.modifierFlags.contains(.shift), toggling: NSEvent.modifierFlags.contains(.command)) },
            onToggleSelection: { model.select(entry, extending: false, toggling: true) },
            onActivate: { model.enter(item, rowID: entry.id) }, onToggle: { model.toggleExpansion(entry) },
            onLoadMore: { model.tree.loadMore(entry) }, onRetry: { model.tree.retry(entry) },
            onMeasure: { model.measure([item]) }, onSave: {}, onDownload: { model.chooseExport([item]) },
            kindOverride: item.isFolder ? model.kind.containerName : item.kindLabel,
            sizeOverride: item.bytes == nil && item.isFolder ? nil : item.sizeLabel,
            downloadHelp: "Download this \(item.isFolder ? model.kind.containerName.lowercased() : "file") to this Mac")
    }
    private func saveWidth(_ column: BrowserSortColumn, _ width: CGFloat) {
        let value = Double(BrowserTreeColumnLimits.clamped(width, for: column))
        switch column { case .name: nameWidth = value; case .size: sizeWidth = value; case .kind: kindWidth = value; case .modified: dateWidth = value }
        liveWidths[column] = nil
    }
    private func toggleColumn(_ column: BrowserSortColumn) {
        switch column { case .name: return; case .size: showsSize.toggle(); case .kind: showsKind.toggle(); case .modified: showsDate.toggle() }
        if model.browserSortColumn == column { model.toggleSort(.name) }
    }
    private func resetColumns() {
        nameWidth = 250; sizeWidth = 76; kindWidth = 104; dateWidth = 156
        showsSize = true; showsKind = true; showsDate = true; liveWidths = [:]
    }
}

struct NativeDriveFileGrid<Context: View>: View {
    @ObservedObject var model: NativeDriveModel
    @ViewBuilder var menu: ([CloudDriveItem]) -> Context
    var body: some View {
        let selected = model.selectedItems
        GeometryReader { viewport in
            let scale = model.zoom
            let spacing = max(8, 12 * scale), padding = max(10, 14 * scale), minimum = 104 * scale
            let count = max(1, Int((max(viewport.size.width - padding * 2, minimum) + spacing) / (minimum + spacing)))
            let columns = Array(repeating: GridItem(.flexible(minimum: minimum, maximum: minimum + 24 * scale), spacing: spacing, alignment: .top), count: count)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: max(12, 16 * scale)) {
                        ForEach(model.visibleRows) { entry in
                            let item = entry.item
                            BrowserThumbnailTile(item: item.browserItem, scale: scale, sizeLabel: item.sizeLabel,
                                systemImage: item.symbol, isActive: model.selection.contains(item.id), isSelected: model.selection.contains(item.id),
                                isMeasuringSize: false, isMeasurementQueued: false, isSavedToPikPak: false,
                                onSelect: { model.select(item, extending: NSEvent.modifierFlags.contains(.shift), toggling: NSEvent.modifierFlags.contains(.command)) },
                                onToggleSelection: { model.select(item, extending: false, toggling: true) },
                                onActivate: { model.enter(item) }, thumbnailContent: AnyView(NativeMediaThumbnail(item: item, kind: model.kind)))
                                .id(item.id).browserContextMenu { menu(model.selection.contains(item.id) ? selected : [item]) }
                        }
                    }.padding(.horizontal, padding).padding(.vertical, max(12, 16 * scale))
                        .frame(minHeight: viewport.size.height, alignment: .top)
                        .background(Color(nsColor: .controlBackgroundColor).onTapGesture { model.selection = [] }.browserContextMenu { menu([]) })
                }.onChange(of: model.selection) { _ in if let id = model.focusedItemID { proxy.scrollTo(id) } }
                    .onAppear { model.gridColumnCount = count }
                    .onChange(of: count) { model.gridColumnCount = $0 }
            }
        }
    }
}
