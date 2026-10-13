# One workspace across providers

Switching between PikPak, iCloud Drive, Apple Photos and Local Disk keeps the same navigation
and presentation. The provider changes the content, available actions and
connection details. It does not replace the layout.

## Shared structure

- The drive switcher and All Drives control stay above the workspace.
- The sidebar contains Browser, Links and Settings, followed by storage
  information and the Account shortcut. Transfers are managed from Status.
- Entering a drive from Home or the drive switcher opens Browser. Provider
  locations, file selections and ongoing work stay separate. Each workspace window
  owns its navigation and account selection.
- ⌘F searches the active drive and ⌘⇧F searches from the PikPak root. Search
  commands observe drive and login changes immediately. From Find Similar Files,
  they raise or reopen its owning browser and keep the scan window running.
- At narrow widths the sidebar temporarily overlays from the left edge without
  changing the saved visibility preference. A short sidebar scrolls vertically;
  Home uses compact spacing and an adaptive drive-card grid.
- List/thumbnail mode, the size for each mode, sidebar visibility and preview
  visibility, column widths and preview divider position are shared preferences.
- Every page uses the same margins, card surface, spacing and 34-point footer.
- Home drive cards pair readable status text with a colored dot: green for a
  saved PikPak account or connected drive, amber when sign-in or access needs
  attention, blue while checking, and gray for a disconnected Photos library
  whose macOS permission is still available. A saved account is labeled
  “Account saved” until its sign-in has been verified.

## Browser

PikPak folder context menus are built on right-click and retained by AppKit until
dismissal. Row hover, folder metadata and background progress can continue
updating without rebuilding the open Expand Folder submenu. Only the factory
for the next opening is refreshed. The invisible menu target receives right-click
and Control-click; left-click, disclosure and drag gestures stay with the row.

All providers use `FinderBrowserToolbar` and `FinderBrowserSplit`: back, location,
display mode, item size/sort, search, upload, download, trash, new container and
refresh. Actions have the same positions and hover labels. Photos creates albums;
native uploads/downloads import/export content through macOS. The toolbar
scrolls horizontally when its actions cannot fit, keeping every action reachable.

General → Preview placement chooses Right (default) or Bottom across drives.
The resizable preview has the same minimum width, header arrangement and empty
state. Small windows scroll the file/preview pair along its layout direction
instead of clipping either pane. Bottom placement gives the preview 55% of the
default split. In both placements, and for every drive (PikPak, This Mac, external
disks, network shares, iCloud Drive and Photos), metadata and actions are in an
information popover beside the header, so the media area reserves no metadata
strip; the height grip remains available below the image/player. Name, Size, Kind and Date Modified columns occupy the file region. The
preview canvas always fills the pane's width and stays inside the available height.
A bottom grip adjusts height only;
double-click it to fit the available height. Dragging uses global coordinates so
the handle follows the pointer. Shrinking a window temporarily clamps the height
without losing the preferred height. All providers share these controls, and
obsolete saved canvas widths no longer affect the layout.

The file headers, rows and thumbnail tiles are shared across providers. Native
folders and Photos albums expand inline using the disclosure arrow, just like
PikPak. Double-click, Return or Open Folder/Album opens a container as the current
location. Right expands or selects the first child; Left collapses or selects the
parent. Up/Down, range selection and Quick Look follow the visible tree.
Photos dates describe its asset metadata.

Context menus use the standard macOS button style, isolated from the app's
hover-sensitive toolbar buttons. Open With and the PikPak expansion-depth menu
use native submenu tracking; moving onto a submenu does not rebuild its parent.

Native expansion loads only disclosed containers, with an inline loading spinner,
empty indicator, retry action and paginated More control. Up to four metadata
requests run at once; no media is downloaded for expansion. Visible rows are
cached between structural changes, and sibling sorting happens off the main
thread. Refresh updates expanded children after file changes. Collapsing a folder
retains cached expansion state while moving hidden selection to the visible parent.
Photos row identities include their album path, so a shared asset can appear in
several expanded albums without conflicting row IDs.

Disconnected Browser pages keep the toolbar and use one connection-card design.
Unavailable controls remain visible and disabled.

## Transfers

The footer's Status control combines transfer progress, scans and maintenance.
File → Show Transfers opens detailed PikPak queue management; native transfers
are listed directly in Status. Browser navigation is available during transfers.

Native imports are Uploads, and exports are Downloads. Direction is captured
when starting the operation. Maintenance, previews and scans are not counted as
transfers. Active and queued transfers expose Pause/Resume and Cancel. Failures
retry with a delay while the operation remains active; pausing suspends retries.
Cancel removes incomplete local copies, keeping already completed files. Native
copy operations wait off Swift's cooperative executor, and paused/retrying
transfers release their worker slot. Unknown progress uses an activity indicator.

## Links and settings

Links exists only in PikPak, where it browses shared links and saves their files. iCloud Drive,
Photos and Local Disk (this Mac, external disks and network shares) have no Links tab in the
sidebar and no Links item in the Go menu, so there is nothing to open and no placeholder page.
`FinderWorkspaceSection.standard` is the list every non-PikPak drive shows; PikPak lists `allCases`.

Settings is the same window and tab set across drives. The Account shortcut goes
to PikPak accounts or native drive connections as appropriate.
Accounts explicitly labels PikPak identities and lists Apple service connections
separately. Apple Account names and email addresses are not read from macOS.
Photos shows its app connection independently of macOS permission. Check Access
reports a result and check time without resetting the browser or interrupting
work. Disconnect persists across relaunches and leaves the library and system
permission intact; permission can be revoked through Photos Privacy Settings.

General → Reset Layout restores sidebar/preview visibility, split view, canvas
height, file-column widths/visibility, list mode and item zoom. The update
applies to open workspaces, including an expanded preview. Account connections,
locations, transfer settings and background tasks are retained.

## iCloud storage

The iCloud sidebar and Drives settings show remaining personal-account space
from macOS's read-only `brctl quota` command. This covers the shared iCloud
account quota, not the selected folder or the Mac's disk. The command does not
report the plan's total capacity, so the UI does not invent used space or a
percentage bar. Storage Settings opens the system iCloud page for that breakdown.

The request runs asynchronously with an eight-second timeout, cancellation and
strict parsing. Tab changes reuse a recent result; refresh, returning to the app
and completing native work request a new value. Disconnect clears cached data
and ignores late responses. Unavailable information is never displayed as zero.

## Implementation and verification

`MediaPreviewView` supplies the shared video/audio canvas and transport bar.
AVKit renders media with its controls disabled. `MediaPlaybackController` observes
only the player view; preferences live in `FinderSettings.playback` and persist
across files, providers and launches. Reset Layout does not reset playback choices.
PikPak retains its streaming/retry owner. Native media preparation is cancellable
and owned by the drive model, so resizing or expanding never recreates playback.
The app only removes its own preview staging directory, never an iCloud original.

Shared components live in `macos/FinderWorkspaceChrome.swift`. Provider adapters
remain in `ContentView.swift` and `NativeDriveWorkspace.swift`; native transfers
use `NativeDriveTransfers.swift`. Extend the common components for layout changes
instead of introducing a separate provider layout.

`NativeDriveTests.swift` checks that drive entries open Browser and preserve
selection, cancel stale tab preparation without cancelling transfers, and keep transfer
directions and provider activity independent. `NativeDriveUITestApp.swift` supplies
synthetic content for checking all tabs, both appearances, preview visibility and
minimum window size without connecting to personal accounts or Photos. Its
synthetic session supports multiple windows sharing the same account, browser,
transfers and scans through File → New Window. `LocalDiskWorkspaceTests.swift` verifies local boundaries and
Show in Folder routing; `SimilaritySessionTests.swift` verifies scan state reset.
`NativeDriveTreeTests.swift` checks disclosure, nested selection/navigation, lazy
loading, cancellation, sorting, pagination, refresh/Undo and Photos row identities.
