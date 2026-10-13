import AppKit
import SwiftUI

extension View {
    /// Menu buttons must use AppKit's own tracking. Inheriting
    /// FinderButtonStyle adds SwiftUI hover state to a submenu's trigger;
    /// entering it then rebuilds the NSMenu while AppKit is opening its child.
    @ViewBuilder
    func browserContextMenu<Items: View>(nativeMenu: (() -> NSMenu)? = nil,
                                        usesNativeCanvas: Bool = false,
                                        @ViewBuilder _ items: () -> Items) -> some View {
        if usesNativeCanvas {
            self
        } else if let nativeMenu {
            overlay { BrowserNativeContextMenu(makeMenu: nativeMenu) }
        } else {
            contextMenu { items().buttonStyle(.automatic) }
        }
    }
}

/// Context-menu icons use one fixed, eagerly rendered template instead of a
/// live SF Symbol whose optical size can inherit the row's font/animation.
/// Each logical 16-point image includes native 1x and 2x bitmap representations.
@MainActor
enum BrowserContextMenuStyle {
    static let iconSize = NSSize(width: 16, height: 16)
    static let fontSize: CGFloat = 13

    static func label(_ title: String, systemImage: String) -> Label<Text, Image> {
        Label {
            Text(verbatim: title).font(.system(size: fontSize))
        } icon: {
            Image(nsImage: icon(named: systemImage))
        }
    }

    static func icon(named name: String) -> NSImage {
        FinderSymbolImage.template(named: name, style: .menu)
    }
}
