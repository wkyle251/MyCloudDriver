import AppKit

@main struct FinderSymbolImageTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let settings = ["gearshape", "gauge", "person.crop.circle", "externaldrive"]
        let menus = ["chevron.right", "chevron.down", "folder", "folder.badge.plus",
                     "arrow.triangle.merge", "sum", "eye", "pencil", "arrow.down.circle",
                     "archivebox", "trash", "doc.on.doc", "arrow.clockwise", "xmark.circle"]
        for (style, names) in [(FinderSymbolImage.Style.settingsTab, settings), (.menu, menus)] {
            for name in names {
                let icon = FinderSymbolImage.template(named: name, style: style)
                let expected = NSSize(width: style.side, height: style.side)
                precondition(icon.size == expected && icon.isTemplate)
                let representations = icon.representations.compactMap { $0 as? NSBitmapImageRep }
                precondition(representations.count == 2 && icon.representations.count == 2)
                for (index, bitmap) in representations.enumerated() {
                    precondition(bitmap.size == expected && bitmap.pixelsWide == style.side * (index + 1))
                    precondition(bitmap.pixelsHigh == bitmap.pixelsWide)
                    precondition((0..<bitmap.pixelsHigh).contains { y in
                        (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
                    }, "Icon must render at both display scales: \(name)")
                }
                for pointSize: CGFloat in [8, 13, 20, 48, 96] {
                    let configured = icon.withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold)) ?? icon
                    precondition(configured.size == expected, "Native symbol configuration must not resize a tab/menu icon")
                    precondition(FinderSymbolImage.template(named: name, style: style) === icon)
                }
            }
        }
        let menu = FinderSymbolImage.template(named: "gearshape", style: .menu)
        let toolbar = FinderSymbolImage.template(named: "gearshape", style: .settingsTab)
        precondition(menu !== toolbar && menu.size != toolbar.size, "Menu and toolbar configurations must not mutate each other")
        print("PASS stable icons: all four Settings tabs and 14 menu icons, 1x/2x rendering, native reconfiguration and independent cached sizes")
    }
}
