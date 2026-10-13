import AppKit

/// Up and Down walk the files wherever a preview is shown. A focused seek or volume slider owns only Left/Right
/// and Home/End, so these keys can never change the time or the volume.
@main struct PreviewKeyRoutingTests {
    static func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @MainActor static func main() {
        setbuf(stdout, nil)
        let seek = MediaSliderControl(frame: .init(x: 0, y: 0, width: 200, height: 18))
        seek.isEnabled = true; seek.maximum = 100; seek.value = 50
        var commits: [Double] = []
        seek.onCommit = { value, _ in commits.append(value) }
        seek.keyDown(with: key(126)); seek.keyDown(with: key(125))
        precondition(seek.value == 50 && commits.isEmpty, "Up and Down must not change the playback time: \(seek.value)")
        seek.keyDown(with: key(124)); precondition(seek.value == 55)
        seek.keyDown(with: key(123)); precondition(seek.value == 50)
        seek.keyDown(with: key(119)); precondition(seek.value == 100, "End jumps to the end")
        seek.keyDown(with: key(115)); precondition(seek.value == 0, "Home jumps to the start")
        precondition(commits == [55, 50, 100, 0], "Only Left, Right, Home and End seek: \(commits)")
        print("PASS seek slider: Left/Right/Home/End seek, Up/Down never change the time")

        let volume = MediaSliderControl(frame: .init(x: 0, y: 0, width: 120, height: 18))
        volume.isEnabled = true; volume.isVolume = true; volume.maximum = 1; volume.value = 0.5
        var changes: [Double] = []
        volume.onCommit = { value, _ in changes.append(value) }
        volume.keyDown(with: key(126)); volume.keyDown(with: key(125))
        precondition(volume.value == 0.5 && changes.isEmpty, "Up and Down must not change the volume: \(volume.value)")
        volume.keyDown(with: key(124)); volume.keyDown(with: key(123))
        precondition(changes.count == 2 && abs(changes[0] - 0.55) < 1e-9 && abs(changes[1] - 0.5) < 1e-9)
        print("PASS volume slider: Left/Right adjust, Up/Down never change the volume")

        for code: UInt16 in [123, 124, 115, 119] { precondition(PreviewKeyRouting.sliderOwns(keyCode: code), "A slider keeps key \(code)") }
        for code: UInt16 in [125, 126, 36, 49, 48, 53, 0] { precondition(!PreviewKeyRouting.sliderOwns(keyCode: code), "A slider must not claim key \(code)") }
        print("PASS routing: a focused slider owns only Left/Right and Home/End")

        // Every tab that lists files next to a preview moves between them, not only the Browser.
        precondition(PreviewKeyRouting.isFilePreviewTab(FinderWorkspaceSection.browser.rawValue, bookmarkBrowserIsOpen: false))
        precondition(PreviewKeyRouting.isFilePreviewTab(FinderWorkspaceSection.links.rawValue, bookmarkBrowserIsOpen: false), "The Links tab navigates like the Browser")
        precondition(PreviewKeyRouting.isFilePreviewTab(FinderWorkspaceSection.bookmarks.rawValue, bookmarkBrowserIsOpen: true), "An open bookmark folder has files and a preview")
        precondition(!PreviewKeyRouting.isFilePreviewTab(FinderWorkspaceSection.bookmarks.rawValue, bookmarkBrowserIsOpen: false), "The bookmark list is not a file list")
        for section in [FinderWorkspaceSection.transfers, .cloudDownloads, .shares, .trash] {
            precondition(!PreviewKeyRouting.isFilePreviewTab(section.rawValue, bookmarkBrowserIsOpen: true), "\(section.title) has no file preview")
        }
        print("PASS routing: Browser, Links and an open bookmark folder move between files; other pages do not")
    }
}
