import AppKit
import SwiftUI

/// Fill the pane's width, with the adjustable preview height and its resize handle below the header. Metadata
/// and actions are in the header's information popover, so they take none of the pane's height.
struct FinderPreviewGeometry {
    static let defaultHeight: CGFloat = 440
    static let minimumHeight: CGFloat = 180
    static let handle: CGFloat = 14
    let maximum: CGSize
    let size: CGSize
    let verticalHandle: CGFloat

    init(available: CGSize, requestedHeight: CGFloat) {
        let width = available.width.isFinite ? max(0, available.width) : 0
        let height = available.height.isFinite ? max(0, available.height) : 0
        verticalHandle = min(Self.handle, height)
        maximum = .init(width: width, height: max(0, height - verticalHandle))
        size = .init(width: width, height: Self.clampHeight(requestedHeight, maximum: maximum.height))
    }

    private static func clampHeight(_ proposed: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimumHeight, proposed.isFinite ? proposed : defaultHeight))
    }

    func resizedHeight(from start: CGFloat, translation: CGSize) -> CGFloat {
        let delta = translation.height.isFinite ? translation.height : 0
        return Self.clampHeight(start + delta, maximum: maximum.height)
    }
}

/// Shared preview for all drives, with one layout for both placements: the file's details and actions are behind
/// the header's information button. The height handle sits below the native media view, so the player's
/// controls cannot consume its mouse events.
struct FinderPreviewPane<Header: View, Media: View, Details: View>: View {
    var resetRevision = 0
    var mediaPlayback: MediaPlaybackController? = nil
    var onPreviewMove: ((Int) -> Void)? = nil
    @ViewBuilder var header: () -> Header
    @ViewBuilder var media: () -> Media
    @ViewBuilder var details: () -> Details
    @AppStorage("previewCanvasHeight") private var savedHeight = 440.0
    @AppStorage("finderPreviewPlacement") private var placement = "right"
    @State private var liveHeight: CGFloat?
    @State private var dragStart: CGFloat?
    @State private var handleHovered = false
    @State private var showsDetails = false
    private var bottom: Bool { placement == "bottom" }

    var body: some View {
        VStack(alignment: .leading, spacing: bottom ? 6 : 12) {
            HStack(spacing: 8) {
                header().frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                Button { showsDetails.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 17)).frame(width: 30, height: 30)
                }.buttonStyle(.borderless).help("Show file details and actions")
                    .accessibilityLabel("File details")
                    .popover(isPresented: $showsDetails, arrowEdge: .top) {
                        ScrollView { details().frame(maxWidth: .infinity, alignment: .leading).padding(18) }
                            .frame(width: 360, height: 270)
                    }
            }
            GeometryReader { viewport in
                let layout = FinderPreviewGeometry(available: viewport.size, requestedHeight: liveHeight ?? CGFloat(savedHeight))
                VStack(spacing: 0) {
                    media().frame(width: layout.size.width, height: layout.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)).allowsHitTesting(false) }
                    heightHandle(layout: layout)
                        .frame(width: layout.size.width, height: layout.verticalHandle)
                }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
        }.padding(bottom ? 10 : 16)
            .background {
                if let onPreviewMove { MediaPreviewKeyboardScope(playback: mediaPlayback, onMove: onPreviewMove) }
            }
            .onChange(of: resetRevision) { _ in cancelDrag(); showsDetails = false }
            .onChange(of: placement) { _ in cancelDrag(); showsDetails = false }
            .onDisappear { cancelDrag() }
    }

    private func heightHandle(layout: FinderPreviewGeometry) -> some View {
        ZStack {
            Rectangle().fill(Color.accentColor.opacity(handleHovered ? 0.09 : 0.001))
            Capsule().fill(handleHovered ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 28, height: 3)
        }.contentShape(Rectangle())
            .onHover { active in
                handleHovered = active
                (active ? NSCursor.resizeUpDown : .arrow).set()
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = layout.size.height }
                    liveHeight = layout.resizedHeight(from: dragStart ?? layout.size.height, translation: value.translation)
                }
                .onEnded { value in
                    savedHeight = Double(layout.resizedHeight(from: dragStart ?? layout.size.height, translation: value.translation))
                    cancelDrag()
                })
            .onTapGesture(count: 2) { savedHeight = Double(layout.maximum.height) }
            .contextMenu {
                Button("Fit Preview Height") { savedHeight = Double(layout.maximum.height) }
                Button("Reset Preview Height") { savedHeight = Double(FinderPreviewGeometry.defaultHeight) }
            }
            .help("Drag to adjust preview height. Double-click to fit the available height. Width always fills the pane.")
            .accessibilityElement()
            .accessibilityLabel("Resize preview height")
            .accessibilityValue("\(Int(layout.size.height)) points high")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 24 : -24
                savedHeight = Double(layout.resizedHeight(from: layout.size.height, translation: .init(width: 0, height: step)))
            }
    }

    private func cancelDrag() {
        liveHeight = nil; dragStart = nil; handleHovered = false
        NSCursor.arrow.set()
    }
}
