import AppKit
import SwiftUI

/// Shared preview for every drive and placement. Media fills the available
/// pane below the header; file details and actions stay in its information popover.
struct FinderPreviewPane<Header: View, Media: View, Details: View>: View {
    var resetRevision = 0
    var mediaPlayback: MediaPlaybackController? = nil
    var isMediaPreview = false
    var onPreviewMove: ((Int) -> Void)? = nil
    @ViewBuilder var header: () -> Header
    @ViewBuilder var media: () -> Media
    @ViewBuilder var details: () -> Details
    @AppStorage("finderPreviewPlacement") private var placement = "right"
    @State private var showsDetails = false
    private var stacked: Bool { (FinderPreviewPlacement(rawValue: placement) ?? .right).layout == .topAndBottom }

    var body: some View {
        VStack(alignment: .leading, spacing: stacked ? 6 : 12) {
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
                    .onReceive(NotificationCenter.default.publisher(for: FinderPopover.dismissAllNotification)) { _ in showsDetails = false }
            }
            GeometryReader { viewport in
                media().frame(width: viewport.size.width, height: viewport.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)).allowsHitTesting(false) }
            }
        }.padding(stacked ? 10 : 16)
            .background {
                if let onPreviewMove {
                    MediaPreviewKeyboardScope(playback: mediaPlayback, isMediaPreview: isMediaPreview, onMove: onPreviewMove)
                }
            }
            .onChange(of: resetRevision) { _ in showsDetails = false }
            .onChange(of: placement) { _ in showsDetails = false }
    }
}
