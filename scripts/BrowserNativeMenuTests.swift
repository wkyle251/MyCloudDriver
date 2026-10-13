import AppKit
import Foundation

@main @MainActor struct BrowserNativeMenuTests {
    static func main() {
        _ = NSApplication.shared
        let height: CGFloat = 29
        for (y, expected) in [(CGFloat(-1), nil), (0, 0), (28.9, 0), (29, 1), (86.9, 2), (87, nil),
                              (CGFloat.infinity, nil), (CGFloat.nan, nil)] as [(CGFloat, Int?)] {
            precondition(BrowserNativeContextMenuCanvas.rowIndex(at: .init(x: 24, y: y), rowHeight: height, rowCount: 3) == expected,
                         "Native menus must resolve the clicked row, including row boundaries and blank space")
        }
        precondition(BrowserNativeContextMenuCanvas.rowIndex(at: .zero, rowHeight: 0, rowCount: 3) == nil)
        precondition(BrowserNativeContextMenuCanvas.rowIndex(at: .zero, rowHeight: height, rowCount: 0) == nil)
        precondition(BrowserNativeContextMenuCanvas.rowIndex(at: .init(x: 0, y: height * 19_999 + 1), rowHeight: height, rowCount: 20_000) == 19_999)
        for fileExtension in ["txt", "mp4", "myclouddriver-unknown-type"] {
            let item = BrowserItem(id: "menu-fixture", name: "Generated.\(fileExtension)", size: 1, kind: .file,
                parentId: "", mimeType: nil, createdTime: nil, modifiedTime: nil, fileExtension: fileExtension,
                iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
            var opens: [URL?] = [], choices = 0
            func menu(enabled: Bool = true) -> BrowserNativeMenu {
                let menu = BrowserNativeMenu(title: "Generated file actions")
                FinderFileApplications.addOpenActions(to: menu, item: item, enabled: enabled,
                    open: { opens.append($0) }, chooseApplication: { choices += 1 })
                return menu
            }
            let initial = menu()
            let host = initial.items.first { $0.title == "Open With" }!
            let submenu = host.submenu!
            precondition(host.isEnabled && !initial.autoenablesItems && !submenu.autoenablesItems)
            precondition(submenu.items.last?.title == "Other…" && submenu.items.last?.isEnabled == true,
                "Open With always has an application chooser, including an unregistered file type")
            initial.performActionForItem(at: 0)
            precondition(opens.count == 1 && opens[0] == nil)
            submenu.performActionForItem(at: submenu.items.count - 1)
            precondition(choices == 1)
            if let entry = submenu.items.first(where: { $0.toolTip != nil }) {
                let index = submenu.index(of: entry)
                submenu.performActionForItem(at: index)
                precondition(opens.last! == URL(fileURLWithPath: entry.toolTip!), "The chosen application URL reaches the open action")
            }
            let originalItems = submenu.items
            for _ in 0..<20 {
                let next = menu()
                precondition(next !== initial && next.items.first { $0.title == "Open With" }?.submenu !== submenu)
                precondition(zip(submenu.items, originalItems).allSatisfy { pair in pair.0 === pair.1 },
                    "Fresh menus must not replace items in an already-open submenu")
            }
            let disabled = menu(enabled: false), count = opens.count
            disabled.update()
            precondition(!disabled.items[0].isEnabled && !disabled.items[1].isEnabled)
            disabled.performActionForItem(at: 0)
            let disabledSubmenu = disabled.items[1].submenu!
            disabledSubmenu.performActionForItem(at: disabledSubmenu.items.count - 1)
            precondition(opens.count == count && choices == 1, "Disabled native menu items cannot dispatch")
        }
        print("PASS Open With: row/boundary hit testing, stable native submenus, registered/unknown file types, default/chosen apps, Other chooser, fresh instances and disabled actions")
    }
}
