import AppKit
import SwiftUI

/// Context-menu icons use one fixed, eagerly rendered template instead of a
/// live SF Symbol whose optical size can inherit the row's font/animation.
/// Each logical 16-point image includes native 1x and 2x bitmap representations.
@MainActor
enum BrowserContextMenuStyle {
    static let iconSize = NSSize(width: 16, height: 16)
    static let fontSize: CGFloat = 13
    private static var icons: [String: NSImage] = [:]

    static func label(_ title: String, systemImage: String) -> Label<Text, Image> {
        Label {
            Text(verbatim: title).font(.system(size: fontSize))
        } icon: {
            Image(nsImage: icon(named: systemImage))
        }
    }

    static func icon(named name: String) -> NSImage {
        if let cached = icons[name] { return cached }
        let result = NSImage(size: iconSize)
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: fontSize, weight: .regular)) {
            for scale in [1, 2] {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                let ratio = min(14 / max(symbol.size.width, 1), 14 / max(symbol.size.height, 1))
                let size = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
                symbol.draw(in: NSRect(x: (16 - size.width) / 2, y: (16 - size.height) / 2,
                                       width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                bitmap.size = iconSize
                result.addRepresentation(bitmap)
            }
        }
        result.isTemplate = true
        result.accessibilityDescription = nil
        icons[name] = result
        return result
    }
}
