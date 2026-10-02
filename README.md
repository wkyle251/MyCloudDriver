# MyCloudDriver

A native macOS app for **PikPak, iCloud Drive, Apple Photos and Local Disk**. Choose a drive
on the home screen, then browse, organise, preview and compare its content in a
consistent workspace. The repository and installed app are named **MyCloudDriver**.

Opening a drive from All Drives or the header switcher always opens Browser.
All four providers share the sidebar, Browser toolbar, list/grid preferences,
preview placement and status footer. Transfers live in Status, alongside scans
and other background work. Features a
provider cannot supply remain clearly marked as unavailable; for example, Links
offers a shortcut to PikPak when viewing iCloud Drive, Photos or Local Disk. See the
[workspace layout](docs/WORKSPACE_LAYOUT.md).

The interface uses SwiftUI and AppKit, with a bundled Rust engine for cloud
operations. PikPak is an unofficial integration and requires your own PikPak
account. iCloud Drive and Photos use the Apple Account configured on your Mac.
Changes to provider APIs can affect functionality.

For PikPak, sign in through **Settings → Accounts**. The app obtains,
verifies, and saves your account session automatically. You do not need to copy
tokens, create an `.env` file, or configure account credentials manually.

[Features](#features) · [Build the app](#build-the-app) ·
[First use](#first-use) · [Troubleshooting](#troubleshooting) ·
[Development](#development)

## Guest Mode

**Settings → General → PikPak · Advanced → Guest Mode** uses anonymous original-share
URLs for PikPak downloads, previews, and similarity scans. It is off by default;
files need an accessible original public share and never fall back to account
downloads. PikPak's guest limits still apply. See [Guest Mode](docs/PIKPAK_GUEST_MODE.md)
for supported files and when the setting takes effect.

## Features

| Area | What you can do |
| --- | --- |
| **Drives** | Open PikPak, iCloud Drive, Apple Photos or Local Disk. Local Disk starts in Home and can use another folder or external disk. |
| **Browser** | Browse in List or Thumbnails, filter by file type or extension, search, select multiple items, rename, move, create folders, and move items to Trash. |
| **Bookmarks** | Right-click a file or folder to bookmark it, then open it from the Bookmarks sidebar tab. Saved items stay with their drive and account. |
| **Transfers** | Manage uploads/downloads from Status, with automatic retry and per-item Pause, Resume and Cancel. Cancel removes incomplete local copies. |
| **Links** | Open multiple shared links, select items across expanded links, save selections to your PikPak, and queue downloads. |
| **Accounts** | Identify and manage PikPak accounts, view live monthly transfer quotas, and review Apple service connections separately. |
| **Maintenance** | Check for duplicates, remove empty folders or `.DS_Store` files, and merge selected folders through the File menu, folder context menu or merge toolbar button. Select at least two sibling folders to enable merging in PikPak. |
| **Similarity** | Browse a scanned file tree, select a reference file, and review individual similarity scores, previews and identical copies. Filter saved scores from 5% without rescanning. |
| **Status** | Follow transfers and scans in the footer; open Status for progress, results, and controls. |
| **Multiple windows** | Open multiple views of the same account, drives, transfers and scans. |

### Provider support

**PikPak transfer quotas:** click **Transfer quota** below Storage in the
PikPak sidebar to see cloud-download, downstream and upload usage, remaining
allowance and the last update time. The display refreshes every minute while
visible, including during downloads, and supports manual refresh. These are
account-wide totals from PikPak, including other apps. Downloads to your Mac,
streaming, previews and originals fetched for similarity scans use downstream
traffic. Cloud-download allowance covers files fetched into PikPak's cloud and
cannot replace downstream allowance. See [quota details](docs/PIKPAK_TRANSFER_QUOTAS.md).

| Function | PikPak | iCloud Drive | Apple Photos | Local Disk |
| --- | --- | --- | --- | --- |
| Browse, search, list/grid, multi-select | Files and folders | Files and folders | Photos, videos and albums | Files and folders |
| Open With and Space Quick Look | Downloads a copy | Fetches cloud-only files as needed | Fetches original media as needed | Opens the local file |
| Import / export | Upload / download queues | Copy into / out of the connected folder | Import media / export originals | Copy into / out of the selected folder |
| Organise | Create, rename, move, copy, Trash | Create, rename, move, copy, Finder Trash | Create/rename albums, add/move album membership, delete | Create, rename, move, copy, Finder Trash |
| Duplicate and similarity scans | Current folder or selection | Current folder or selection | Media, albums or library | Choose a folder, current folder or selection |
| Cleanup and merge | Folder maintenance | Folder maintenance | Empty albums and album merging | Folder maintenance |
| Archive extraction | PikPak's cloud extractor | Background macOS libarchive extraction | Not applicable | Background macOS libarchive extraction |
| Shared links | PikPak links | Not applicable | Not applicable | Not applicable |

Photos uses the system photo library through PhotoKit. It does not expose
arbitrary filename renaming or programmatic undelete. Album edits and membership
changes have Undo; deleted media is restored in **Photos → Recently Deleted**.
Opening or exporting produces the original still image or video, not a Photos
editing session; a Live Photo's paired motion resource is not exported as a
separate video. Photos edits are managed in Apple's app.

iCloud file changes sync through macOS. Native imports and exports start
immediately. Status provides progress and Pause, Resume and Cancel controls
for native and PikPak transfers. Failed work retries in the background; pausing
also suspends retries. Cancelling removes unfinished local copies while keeping
completed files. iCloud rename, move, copy, Trash, cleanup, merge and extraction
support session Undo. Existing PikPak Undo coverage is described below.

- **Finder-style file actions:** right-click for **Open**, **Open With**, and
  **Other…**. Opening a cloud file fetches a local copy for the selected app.
- **Bookmarks:** right-click a file or folder in Browser and choose **Add to
  Bookmarks**. Open the **Bookmarks** sidebar tab to search saved items, open a
  folder, or show a file in Browser. **Remove from Bookmarks** removes the saved
  shortcut. Bookmarks survive app restarts and are scoped to the connected drive
  and PikPak account.
- **Window resizing:** Transfers stacks setup and progress cards, wraps actions,
  and rearranges its transfer columns to fit narrower windows. Smaller windows
  scroll vertically to keep every section reachable.
- **Inline folders:** click the disclosure arrow to expand or collapse a folder
  or Photos album. Double-click or press Return to open it. Left/Right navigates
  the tree; selection and Quick Look include the expanded rows. Refreshing the
  folder you are in — including the automatic refresh after an upload, an Undo
  or a change made in PikPak Management — keeps the outline and the selection;
  only moving to another folder starts from a closed outline.
- **Toggle the focused folder:** in List view, press **⌘⌥Return** (View → Expand
  or Collapse Folder). From a file in an expanded folder, this collapses its
  containing folder and selects that folder. Press it again to expand and return
  to the previous file. Selecting another row clears the remembered file.
- **Select all folders:** press **⌘A** in the PikPak Browser to select every
  folder in the folder you are viewing, leaving files unselected. Right-click
  any of them and choose **Expand All Levels in N Folders** to open all of them
  and every nested subfolder under one cancellable progress bar. Renaming and
  search fields keep the system's own ⌘A.
- **Quick Look:** press Space to open a preview immediately. A loading indicator
  appears while the file is fetched; Up/Down changes the previewed item.
- **Arrow keys in the preview pane:** click anywhere in the pane, including the
  header, video, playback buttons, timeline or volume slider. Left/Right seek
  backward/forward **5 seconds**; Up/Down step to the previous/next item, one at
  a time in both List and Thumbnails. Clicking the file list returns keyboard
  control to the list.
- **File type filter:** choose **Filter** in the Browser toolbar, then Images,
  Videos, Audio, Documents, Archives, Other Files, or a specific **File Extension**
  from the loaded files. Only matching files appear; folders stay visible so you
  can keep browsing, and the count in the filter bar reports matching files. List
  includes files in expanded folders, while Thumbnails filters the current folder.
  The filter applies to loaded items, including new pages added with **Load More**;
  it does not scan unopened folders. Choose **All Types** or **Clear Filter** to
  restore the view. Available in PikPak Browser, iCloud Drive, Photos and Local Disk.
- **Preview placement and sizing:** choose **Settings → General → Preview placement**
  for **Right** (default) or **Bottom**, shared across drives. The media preview
  always fills its pane's width. Drag the
  bottom grip to adjust its height; double-click it to fit the available height.
  Bottom placement puts metadata and file actions behind the header's **ⓘ**
  button, leaving more space for the image or player.
  **Settings → General → Reset Layout** restores pane sizes, preview height,
  sidebar visibility, file columns and list/zoom preferences across all drives.
- **Media player:** video and audio previews use MyCloudDriver's playback bar:
  play/pause, seek, skip 10 seconds, mute, volume and 0.5–2× speed. Volume, mute
  and speed are remembered across files, drives and app restarts. Reset Layout
  keeps these playback preferences. iCloud and Photos show loading progress
  while the selected original is prepared; PikPak streams as data arrives.
  The seek bar shows played content in solid color and AVPlayer's buffered
  ranges in a lighter shade on the same track. Gaps after seeking stay visible;
  buffering is media time available to the player, not a disk-cache percentage.
  Expand **Streaming details** for PikPak's buffer and network information.
  **AVI previews** play inside this same pane using a temporary H.264/AAC copy
  prepared with FFmpeg. PikPak's compatible cloud streams are preferred; when
  only the original AVI is usable, it downloads and converts before playback.
  If a **PikPak MP4 preview** fails to parse, it retries with a fresh cache once, then
  downloads and prepares a compatible temporary copy when necessary. Large
  files take longer to prepare. Originals remain unchanged, and temporary
  copies are removed when the preview closes.
  Video previews also wait for an actual displayable frame. A source that
  opens successfully but cannot display video automatically tries the remaining
  sources or prepares a compatible copy, instead of staying on a QuickTime logo.
  Progress appears during preparation. Changing the selection cancels the work
  and removes the temporary copy; original files stay unchanged.
- **Drag and drop:** drop local files onto a cloud folder to upload them, or
  drag cloud items between folders to move them.
- **Expand folders:** choose **Expand All Levels** from a PikPak folder's
  context menu to open every nested folder directly. Expansion progress can be
  cancelled; folders already opened remain visible.
- **Downloads:** open the footer's Status control or **File → Show Transfers…**
  to manage work. Temporary connection/server failures retry automatically with
  a delay; missing files, denied access and storage errors stay failed until
  corrected and explicitly retried. Pause and
  Cancel are available for active and queued items; Resume retains partial data,
  while Cancel removes that transfer's incomplete download. Each active file
  shows its own network speed; existing partial data is excluded from speed.
  PikPak account and shared-link downloads start up to four files, then keep
  extra connections only when measured total throughput improves by at least
  10%. Successful trials increase capacity faster, within an automatic safety
  ceiling. Reducing new starts lets active partial downloads finish normally.
  An individual expired link or interrupted connection retries without reducing
  capacity for healthy files; service throttling still reduces new starts.
  PikPak downloads, similarity fetching, uploads and managed preview downloads
  connect directly by default and ignore inherited shell/system proxies. The optional app Proxy
  field (CLI: `PIKPAK_PROXY`) remains available for a deliberately chosen route.
  Disk downloads keep a private `.part.resume.json` validator beside each partial.
  Resume checks the file identity, size, ETag and returned byte range. Older
  partials without a validator are checked against a full response before new
  bytes are appended, which can re-download their prefix. Completion and Cancel
  remove the validator. Account/shared downloads use connection and inactivity
  timeouts, so a healthy large file can run beyond 30 seconds. In-app retries
  back off from one second to 60 seconds without an attempt limit and honor
  longer `Retry-After` delays. Standalone CLI transfers allow five attempts.
  The app also restarts interrupted helpers and keeps retrying unavailable
  storage with delays capped at five minutes. Pause and Cancel remain respected.
  See [automatic recovery](docs/AUTOMATIC_RECOVERY.md) for coverage and exceptions.
- **Batch selection:** use checkboxes, Command-click, or Shift-click. Selected
  folders include their contents. In Links, right-click a selected item and
  choose **Save N Items to My PikPak** to save the whole selection.
- **Retry failed links:** choose **Retry Failed Links** above the Links list to
  retry all failed URLs with their saved access codes. Up to four links load at
  once; the progress count and final result appear above the list.
- **Background extraction:** extract supported cloud archives while continuing
  to use the app. Password-protected archives prompt for a password; progress
  appears in the status area.
- **Content similarity:** open **File → Find Similar Files…** to compare actual
  content. The command also works on **All Drives**, where you can choose the
  scan drive directly. Results use an expandable file tree and a ranked match pane with actual
  pair scores, paths and Preview/Open actions. Change the 5–100% minimum score
  without rescanning. Use the expand/collapse buttons beside group search to
  open or close all groups. **Show in Folder** brings the file's original drive
  window forward, opens its folder and selects it. **Move to Trash** is available
  for the reference file and each match, with confirmation before deletion.
  Minimise the window to keep a scan running. Closing pauses and saves it;
  Cancel also keeps progress for Resume. Only **Clear** removes the saved scan
  and its results. Completed results remain available under **Saved scans**.
  FileTwin reports file and vector-reuse progress; the app reports compatible-pair comparisons.
  Unknown totals use an activity indicator.
  Scores are loaded for the selected file, so the UI does not load the full matrix.
  **Export Scan Summary** exports the displayed inventory and identical-copy
  evidence; it does not export the complete score matrix. See the
  [results design](docs/SIMILARITY_RESULTS_DESIGN.md).
  Apple Photos defaults to **Fast Previews**: photo previews and video thumbnails
  compare appearance without fetching full originals. Choose **Originals** before
  a new scan for original-content and byte-identical checks. Saved scans keep
  their mode. Preview scans cannot verify identical originals or choose the
  smallest original; see [Photos scan modes](docs/APPLE_PHOTOS_DOWNLOAD_PERFORMANCE.md).
- **Undo and Redo:** reverse supported Trash, move, upload, rename, and new-folder
  actions. History lasts for the current account's app session. Cleanup tools,
  share imports, and extractions are outside this history.
  **⌘Z** restores deleted files and folders to their original location;
  expanded parent folders stay open and refresh to show the restored items.
  **⌘⇧Z** redoes the action. Text fields keep their own typing Undo.

## Build the app

These steps are for compiling the app from source. The application configuration
used during a build is separate from the account session created by signing in
to the finished app.

### 1. Install the prerequisites

The current build script targets **Apple Silicon Macs (`arm64`)** and sets
**macOS 13.0** as the deployment target. It does not create an Intel or universal
app. Build on an Apple Silicon Mac with a native ARM Rust toolchain.

| Requirement | Setup |
| --- | --- |
| Apple developer tools | Install Xcode or the Command Line Tools from [Apple](https://developer.apple.com/xcode/resources/). The build needs `swiftc`, a macOS SDK, and `codesign`. |
| Rust and Cargo | Install [rustup](https://rust-lang.org/tools/install/). `rust-toolchain.toml` pins **1.98.1**, also required by FileTwin. |
| Python 3.9 or newer | Used by the build configuration helper. [macOS installers](https://www.python.org/downloads/macos/) are available if needed. |
| Git | Used to clone the repository; included with Apple's Command Line Tools. |

Check your tools in Terminal:

```sh
uname -m
xcode-select -p
swiftc --version
rustc -vV
cargo --version
python3 --version
```

`uname -m` should report `arm64`, and the Rust host should be
`aarch64-apple-darwin`. The build was verified with Apple Swift 6.3.3 in Swift 5
language mode, Rust/Cargo 1.98.1, and Python 3.9.6.

### 2. Clone the repository

```sh
git clone https://github.com/wkyle251/MyCloudDriver.git
cd MyCloudDriver
```

Access to this private repository requires an authorized GitHub account. Run
the remaining commands from the repository root.

### 3. Provide application configuration for the build

Source builds need two OAuth **application client secrets**, which are excluded
from Git. These identify the application's Web and desktop client profiles and
are used to perform sign-in; account login does not create them. Obtain the
matching values from the project maintainer through a private channel. Do not
put your account password or refresh token in these fields.

If `.local/pikpak-client-credentials.json` is already configured, skip to
[Build](#4-build). The build script reads it automatically on each build. Users
of the finished app receive this application configuration in the app bundle
and only need to sign in with their own PikPak account.

Create the local configuration without overwriting an existing file:

```sh
mkdir -p .local
chmod 700 .local
if [ ! -f .local/pikpak-client-credentials.json ]; then
  cp pikpak-client-credentials.example.json .local/pikpak-client-credentials.json
fi
chmod 600 .local/pikpak-client-credentials.json
```

Edit `.local/pikpak-client-credentials.json` and fill in both values:

```json
{
  "web_client_secret": "",
  "desktop_client_secret": ""
}
```

| Field | Purpose |
| --- | --- |
| `web_client_secret` | The Web client profile used by the standalone Rust CLI. |
| `desktop_client_secret` | The desktop client profile used for the app's sign-in and session refresh. |

For automated builds, you can instead supply `PIKPAK_WEB_CLIENT_SECRET` and
`PIKPAK_DESKTOP_CLIENT_SECRET` through the build environment. Environment values
override the JSON file. The build helper does **not** load `.env` automatically.

Empty values stop the build. The secrets are embedded in local build artifacts,
so keep `.local/`, `target/`, and `dist/` out of Git. All three are covered by
[`.gitignore`](.gitignore).

### 4. Build

Provision FileTwin's native assets once before building. These are public model
and decoder assets, **not account credentials**, and are excluded from Git.
The setup script verifies pinned SHA-256 checksums and preserves component
notices. If you already have FileTwin's verified ONNX model:

```sh
python3 vendor/FileTwin/scripts/setup-native.py \
  --model-dir .local/filetwin-models \
  --onnx /absolute/path/to/sscd_disc_mixup.onnx
```

Otherwise, create a separate Python environment for the one-time model
conversion. Use a Python version supported by the pinned packages (the existing
FileTwin environment can also be used):

```sh
python3 -m venv .local/filetwin-conversion
.local/filetwin-conversion/bin/pip install -r vendor/FileTwin/scripts/model-requirements.txt
python3 vendor/FileTwin/scripts/setup-native.py \
  --model-dir .local/filetwin-models \
  --conversion-python .local/filetwin-conversion/bin/python
```

Provisioning explicitly downloads the public model and native runtimes.
Ordinary builds and scans do not download models. You may set
`FILETWIN_MODEL_DIR` to another provisioned directory. Provision the bundled
local BitTorrent engines once (pinned sources, macOS 13+, system libraries),
then build:

```sh
python3 scripts/prepare-torrent-engine.py
python3 scripts/prepare-libtorrent-engine.py
./scripts/build-app.sh
```

The script builds the Rust engine and FileTwin worker with locked dependencies,
compiles the native interface and C archive reader, bundles the model, ONNX Runtime, PDFium,
the TCP/µTP libtorrent helper and legacy aria2 source/license, injects the local client configuration,
and applies an ad-hoc signature. **Transfers → Torrents** supports local selective
downloads from magnets and `.torrent` files, plus a **Download to PikPak** option
that relays selected files through RAM or storage with pause/resume and restart recovery.
Storage retains uploaded pieces for sharing, defaults to leaving 100 GB free,
and offers a live **Storage Limit…** control. Lower limits drain confirmed files
while preserving partial data. Unchanged torrent files reuse verified resume
checkpoints to avoid a full piece scan on every resume;
see [Torrent transfers](docs/LOCAL_TORRENTS.md).
The completed app is:

```text
dist/AppBuild.noindex/MyCloudDriver.app
```

The `AppBuild.noindex` folder keeps the development copy out of Spotlight.
Use the installed copy in `~/Applications` for everyday launches.

Repeated builds reuse optimized Swift objects and dependency information in
`.build/app-swift`. [Swift's incremental compiler](https://github.com/swiftlang/swift/blob/main/docs/Driver.md#incremental-builds) tracks dependencies between files and
recompiles affected files; an unchanged build reuses the executable. Compilation
uses up to 12 parallel jobs, with a lower limit on Macs with less memory. Override
that limit with `MYCLOUD_BUILD_JOBS=18 ./scripts/build-app.sh` if desired.
Release optimization remains enabled. `./scripts/build-app.sh --clean` resets the
Swift cache while retaining the downloaded models and native engine builds.
Compiler, SDK, source-list and compiler-option changes invalidate the cache.
Failed builds leave the previous signed app bundle available.

No Xcode project or workspace file is needed: the script invokes the compilers
directly. The finished app includes its Rust engine, so end users do not need
Rust, Cargo, or Python installed to run it.

Audio, video and HEIF/AVIF similarity also require **FFmpeg 9** and **ffprobe 9**
on the user's Mac. The app detects them in `/opt/homebrew/bin` or
`/usr/local/bin`. For Homebrew installations, use `brew install ffmpeg` and
check `ffmpeg -version`. Other file types can be scanned without them; missing
decoders are reported in scan coverage.
AVI preview conversion and MP4 recovery use the same FFmpeg installation (ffprobe is not needed
for previews). If FFmpeg is missing, the preview offers IINA when installed or
explains that FFmpeg is required.

Image and video similarity require **macOS 14 or later**, the minimum version
of the bundled ONNX Runtime. On macOS 13 those two content toggles are disabled;
the rest of the app, document/audio similarity and byte-identical checks remain
available. This does not change the app's macOS 13 deployment target.

### 5. Install and launch

Build and install in one command:

```sh
./scripts/build-app.sh --install
```

To install an already completed build, run `python3 scripts/install-app.py`.
The installer verifies and stages the new bundle and creates a verified rollback
ZIP before quitting the installed app. It waits for the app and its helpers to
exit normally, replaces the bundle, and launches it. If the installed files
already match, it skips the backup and replacement and leaves a running app alone.

For a manual installation:

1. Quit any running copy of **MyCloudDriver** after its active work finishes.
2. In Finder, copy `dist/AppBuild.noindex/MyCloudDriver.app` into `~/Applications`. Create
   that folder if necessary; choose **Replace** when updating an existing copy.
3. Launch the app from `~/Applications`.

You can launch that installed copy from Terminal:

```sh
open "$HOME/Applications/MyCloudDriver.app"
```

Keep rollback copies as ZIP archives. Loose backup `.app` bundles share the
same app identity, and macOS launchers can open an older copy by mistake.
When upgrading from **My PikPak for Mac**, archive that old app and remove its
loose bundle before launching MyCloudDriver. Both versions intentionally share
the same bundle identifier and private data location, preserving accounts and
transfer history.
For backups in this project's `dist/installed-backup-*` or `dist/update-backup-*`
folders, run:

```sh
python3 scripts/archive-app-backups.py
```

The helper verifies and archives those backups, removes their launcher
registrations, and registers the app in `~/Applications`. Quit any running
backup copy before using it.

The generated app is signed for local use. It is not Developer ID signed or
notarized; public distribution requires a separate signing and notarization
process.

## First use

1. Choose a drive on the home screen:
   - **PikPak:** sign in through **Settings → Accounts**. The app verifies and
     saves the session automatically.
   - **iCloud Drive:** choose **Connect Folder**, then select iCloud Drive or
     one of its folders from the macOS picker. The saved connection is restored
     on subsequent launches. Enable iCloud Drive in System Settings first.
   - **Apple Photos:** choose **Allow Photos Access** and answer the macOS
     permission prompt. Photos/iCloud Photos must already be configured on this Mac.
   - **Local Disk:** browse Home immediately. **Choose Folder or Disk…** in the
     sidebar or Settings → Drives selects another local folder or external disk.
2. Use **Browser** to navigate your folders. Choose **View → as List** or
   **View → as Thumbnails** to change the display.
3. In PikPak, select items and choose **Add Selected Items to Download Queue**.
   Open **Status → Transfers** or **File → Show Transfers…** to check the download
   destination and manage progress. Transfers continue while you browse.
4. In iCloud Drive, Photos or Local Disk, use **Import…** or drop files into the open
   location. Use **Export…** to save selected items to a folder on this Mac or a writable external disk.
   In PikPak, use **File → Upload Files or Folders…** or drop onto a destination folder.
   In Local Disk, right-click files or folders and choose **Upload to PikPak** to use
   the upload destination selected in Transfers. External disks must be mounted
   and readable; read-only disks also support preview and uploads. Ejecting a disk
   clears its preview and pauses its active upload with progress saved. Reconnect
   the same disk, then resume the upload from Transfers. The Local Disk browser
   becomes available again automatically when its saved folder returns.
5. In **Links**, add a share URL and an access code if needed. Expand the link,
   select its files or folders, and right-click to save or download them.

Use **All Drives** or **Go → All Drives** to return home. Settings → Drives
manages the saved iCloud/Local Disk folders and Photos access. **Check Access** shows the Photos
permission result and check time while preserving your current album and work.
**Disconnect** keeps Photos disconnected from MyCloudDriver across relaunches;
it leaves your library and macOS permission unchanged. Revoke that permission in
**System Settings → Privacy & Security → Photos** if needed. Apple Account names
and email addresses are managed in macOS and are not read by this app.
The iCloud sidebar shows available personal-account storage reported by macOS,
with Refresh and Storage Settings controls. Plan capacity and a full usage
breakdown remain in System Settings; local disk space is not used as iCloud quota.
Uploads and downloads automatically adjust concurrent transfers to measured
connection speed. They start with up to four files, keep additional connections
when throughput improves, and reduce concurrency after failures. The internal
ceiling is 64 files per direction; uploads also bound multipart requests. No
worker setting is needed. Existing saved limits are ignored by the app.
Downloads use one continuous queue across selections, destinations and shared
links. Newly selected files enter the running queue, and folders feed files into
it as each page is discovered. There is no batch to finish before another
selection can start. Per-file pause and retry free capacity for other files;
Pause All holds new selections too. Saved unfinished work waits for Resume after
relaunch, preserving partial files and cancellation exclusions.
Settings contains the download folder and Resources, which shows
CPU/memory usage and the background tasks responsible for it across all open
windows. The GPU panel shows device utilization across this Mac, including other
apps. Similarity task rows show their actual CPU/CoreML backend and active CoreML
jobs. A missing GPU counter is shown as unavailable. Maintenance
commands are in **File**; progress and results appear in the footer's status
control.

### Multiple workspace windows

Choose **File → New Window** (Command-N). Each window shows the same session:
account, drive, folder, selection, previews, transfer queues and scans. Opening a
window preserves the current location and does not start another transfer or scan.
Changing the account or navigating updates every browser window.

There is no app-imposed limit on windows, and no Split mode.
File commands act through the focused window.
Use the **Window** menu to switch windows; each title includes its drive,
PikPak account name when available.
Closing one browser keeps shared work running in the remaining browser, scan or
Transfers windows. Closing the last window saves unfinished work and exits.
Move and resize each window independently.
Narrow windows temporarily tuck the sidebar behind the left edge without changing
your saved sidebar preference. The home screen and short sidebars scroll as needed.

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New window | Command-N |
| All Drives | Command-Shift-H |
| Browser / Links | Control-Command-1 / 3 |
| Show Transfers | Command-Shift-T |
| List / Thumbnails | Command-1 / 2 |
| Quick Look | Space; Up/Down changes the selected item |
| Close Quick Look | Space or Escape |
| Upload files or folders | Command-Shift-U |
| Add selection to download queue | Command-Option-D |
| Move selection to Trash | Command-Delete |
| Expand / collapse focused folder (List) | Command-Option-Return |
| Undo / Redo | Command-Z / Command-Shift-Z |
| Show status | Command-Shift-I |
| Refresh | Command-R |

## Find similar files

1. Choose **File → Find Similar Files…**.
2. Choose **PikPak**, **iCloud Drive**, **Apple Photos** or **Local Disk** in the
   scan-drive menu. **Choose Folder…** browses folders directly in PikPak or
   iCloud Drive, and opens a native folder picker for Local Disk. Photos offers
   **Choose Album or Library…**. Choosing a scan location does not change Browser.
   The scope shows the selected path or album.
   Folders include descendants. Each drive keeps a separate scope and result set;
   files from different drives are not mixed into one scan. Cloud originals load
   into a bounded RAM queue while analysis processes ready files. Local Disk
   requires no PikPak login.
3. Set a minimum score from **5% to 100%**. All supported document, image, audio
   and video types are included automatically. **Include byte-identical copies**
   also checks SHA-256 for formats without a similarity decoder. **Scan Resources…**
   offers hardware-based defaults or custom worker and memory limits.
4. Start the scan. Browsing, transfers and other background tasks remain
   available. Discovery feeds a metadata queue while available workers analyse
   files already found. The progress panel shows found, queued, downloading,
   ready, reading, analysing and processed counts, bytes read and elapsed time. The total
   stays open while discovery is running; a percentage appears once discovery
   finishes. Comparison follows after the queue drains. Each source also has progress and Cancel in the
   footer and its own entry in **Settings → Resources**.
5. Results open in **Groups**, with a default similarity of **90%**. Adjust the
   slider from **5% to 100%** after scanning to regroup the saved comparison matrix;
   originals are not read, downloaded or encoded again. Every pair in a group
   must meet the cutoff. Group cards show the weakest pair or verified identical
   content. Lowering the cutoff grows or merges existing groups; it does not
   reshuffle their members. A file can still have matching pairs outside its assigned group.
6. Choose **All files** to browse the complete scanned tree, including unmatched
   and unavailable files. Select a file to see its matches across the whole scan.
   **All scores** displays the complete available score row, including values
   below the group threshold; unavailable comparisons are not counted as zero.
   Open or preview files, inspect coverage, or export the scan summary as JSON.
   Choose **Show in Folder** to bring that file's original drive window forward,
   open its containing folder and select it for keyboard navigation.
7. Use **Move to Trash** on a reference file or match to remove the original.
   PikPak uses its cloud Trash; local and iCloud files use Finder's Trash;
   Apple Photos uses Recently Deleted. Confirmed deletions are hidden from
   results, including regrouping and saved score rows. Undo/Redo in the owning
   drive window also updates the results for PikPak, iCloud and Local Disk.
   Restore Photos assets through **Photos → Recently Deleted**.

Cloud analysis reads originals, including full-resolution images; it does not
use Browser thumbnails for similarity scores or identical-copy checks.
PikPak folder listing retries transient errors and reports access failures in
scan coverage. If no files can be analysed, the scan shows the failure reason
instead of presenting an empty successful result.
PikPak scan download connections start at up to four and trial higher concurrency
only while queued work and RAM allow it. Increases are retained when measured
aggregate throughput improves by at least 10%, with a ceiling of 64 independently
of analysis workers. Provider throttling reduces the allowance. The original
buffer and ready-queue allowance is configured by bytes. Temporary HTTP/server errors, interrupted copies and
expired content links retry with fresh links and backoff, capped at 30 seconds
between attempts in saved app scans. Server retry delays can extend that wait.
Scans without a recovery checkpoint allow five attempts and report a provider
cooldown longer than five minutes for a later retry. Waiting and retrying downloads appear in scan
progress and do not count as failures before retries finish. Large downloads
use connection/inactivity limits rather than the short metadata timeout.
Similarity scans keep application-owned originals **in RAM**, without a disk
fallback. PikPak downloads go into bounded buffers. Photos streams through a
private pipe (which stores no file content); local/iCloud inputs are read directly
and native decoder copies stay in RAM. Videos can seek through memory without
creating a temporary media file. Buffers are released after completion, cache
reuse, failure or cancellation. A separate download pool feeds completed
originals into a bounded RAM queue. Connections grow after successful downloads
and back off when the provider is busy; downloads and retry waits do not occupy
analysis slots. Known file sizes and recent delivery rates govern RAM admission.
A file waiting to start holds no connection, so smaller files can proceed when
they fit.

Photos originals with unknown sizes start with one eighth of Download RAM as
their possible maximum, allowing up to eight concurrent original requests.
They reserve small receive windows as bytes arrive. A larger original releases
its partial buffer and retries with a larger allowance, up to the full pool;
this can repeat part of the fetch. The RAM limit remains enforced. See
[Apple Photos download performance](docs/APPLE_PHOTOS_DOWNLOAD_PERFORMANCE.md).

**Scan Resources → Download RAM** controls the original-buffer allowance in GB.
Together with **Analysis RAM**, it forms the total scan allowance, whose maximum
is the Mac's full physical RAM. For example, 12 GB Download RAM and 52 GB
Analysis RAM use a 64 GB total. Receive windows account for incoming bytes once;
decoder copies use analysis memory only while processing. Files wait for a safe
receive window before fetching more content. An original that cannot fit reports an actionable memory
issue; increase Download RAM to retry. There is no cumulative cloud download
cap. macOS can swap RAM to disk, and iCloud/Photos may retain their own managed
copies; this is not a guarantee of zero operating-system storage activity.
Derived vectors, saved comparisons, run metadata and model caches still use
storage. This policy applies to similarity scans, not user-requested Downloads
or originals opened in another application.

**Scan Resources…** offers Automatic or Custom Analysis RAM and Download RAM.
Memory uses GB, with decimal entries such as 0.5 or 1.5 accepted. Automatic derives
its RAM defaults from physical memory while reserving capacity for other work.
Older saved settings retain their RAM amounts, with a default download budget
of one quarter of the total, capped at 12 GB. Worker and batch preferences are
accepted for compatibility but no longer constrain new or resumed app scans.
A separate ready queue holds downloaded originals within Download RAM. Ready
files start when their estimated reading/decoder memory fits Analysis RAM;
text and documents start with smaller allowances than images and media. Native
reader copies are charged at their full byte size. A decoder can request more
RAM and retry after releasing its old allowance. Large waiting files do not
block smaller ready files that fit. There is no input batch to fill or wait for.
The dedicated scan helper also reserves file-handle capacity for its worker
pipes, open originals and connections. It raises its own soft limit within the
existing hard limit; if the environment prevents this, it admits fewer workers
instead of failing queued files. System limits and saved resource settings are
unchanged.

**Scan Resources → Processing** offers **Automatic** and **CPU Only**.
Automatic checks CoreML for image/video vectors on Apple Silicon, falling back
to CPU when unavailable. Persistent visual workers share the GPU /
Neural Engine through CoreML while CPU work continues. Visual capacity grows
with Analysis RAM, and each file must fit its reader and decoder reservation;
memory-scheduled scans have no fixed two-job CoreML limit. Both use the same RAM
allowance. Existing scans retain their backend on Resume; CPU and CoreML visual
vectors have distinct profiles. One encoder invocation retains its
worker pool and loaded models across the scan. FileTwin 0.2 returns content IDs
and vectors; MyCloudDriver saves their compatible comparisons for review. New
scans reread and hash current content, then reuse saved vectors when the content
and profile match, even after a rename. Progress shows newly analysed and reused
files separately. Resource settings are captured when a scan starts. To change
an active scan, choose **Pause & Adjust Resources…**. The editor opens after the
helper stops and saves its progress. Adjust Analysis RAM or Download RAM,
then choose **Save & Resume**, or **Save** to keep it paused. You can also pause
first and open **Scan Resources…**. These changes belong to this scan and survive
app restarts; other scans and defaults for new scans keep their settings. The
processing backend stays fixed to preserve compatible vectors. The memory
allowance controls estimated admission; model caches and shared pages mean it
is not a hard ceiling on total process RAM. Decoder and operating-system limits
still apply. Progress shows **Analysis RAM reserved** and an **Analysing** count
without a worker quota. Slow downloads, hashing, vector reuse and larger decoder
reservations can leave fewer files analysing at a time. Queue status distinguishes
memory waits from occupied accelerated-processing or operating-system slots.
Use **Pause** and **Resume** in the scan window or Status. Completed file analysis
and comparisons are checkpointed as they finish. Temporary network failures retry
automatically while available analysis continues. After an app quit or unexpected
interruption, open **Find Similar Files** in the original drive/account and choose
the unfinished scan to resume. Unfinished downloads restart in RAM; completed
unchanged files reuse their saved analysis. If the scan had already reached the
comparison stage, it continues using its saved vectors without fetching originals.
Closing the similarity window pauses and retains the scan. Cancel stops work
without removing saved progress; Resume continues it. Completed scans can be
opened from Saved Scans after restarting. Only **Clear** deletes a saved scan
and its comparison matrix, leaving original files and the shared vector cache
intact. Scans stay with their original drive/account when switching accounts.
Closing the main workspace or quitting the app also preserves scans.
Recovery data lives in `checkpoints/<scan-id>` inside the drive/account's
private `Similarity` data directory, beside its saved results. It contains scope, file revisions and compressed
derived vectors, never credentials, signed links or original file contents.

FileTwin supports UTF-8 text, DOCX body text, PDFs with a text layer, raster
images, and supported audio/video containers. It does not perform OCR or search
inside archives. Images use visual content; audio uses sampled sound; video
uses sampled frames, without audio or sequence order. Scores are experimental
cosine similarity, not a probability or a guarantee that files are duplicates.
Groups require every member pair to meet the cutoff.

Files and folders whose names start with a dot, such as `.gitignore`, `.DS_Store`
and `.git`, are always ignored by similarity scans. They are not analysed or
counted as skipped-file warnings. Ordinary names such as `photo.edit.jpg` remain
eligible. **Scan Coverage** separates unsupported content from failed analyses
and groups the reasons, including missing media duration, access errors and
decoder failures. Binary/encrypted data retains exact-copy hashes. Reason totals
cover every file even when the individual issue list reaches 500 entries.
Check **Scan Coverage** before treating an empty result as
exhaustive. Cancelled scans keep their analysed inventory even if comparisons
never started, and are clearly marked incomplete. Scans have no fixed file-count
limit. Cloud/provider metadata queues use temporary disk storage while original
contents remain governed by the configured RAM budgets. The displayed/exported
inventory summary is bounded to 40 MiB and issue details to 500; the saved matrix
retains the full file inventory. Exact-copy evidence in the scan
summary is bounded to 2,000 groups/20,000 members. Saved-matrix grouping supports
up to four million qualifying pairs per request. New scans retain up to four
million compatible scores; larger scans report incomplete comparison coverage
and should be split into smaller scopes for complete results. The app's saved
matrices and private vector cache
are stored under the app's Application Support `Similarity` directory,
separately for each account and local scans. They can include file names and
paths; keep this directory private. Older FileTwin 0.1 score catalogs remain
readable and are not modified by the update.

The persistent vector cache is **`filetwin-vectors.f32.zst`**. It stores exact
float32 bits in byte planes and compresses them with Zstandard; vector values
and similarity scores are unchanged. Existing `filetwin-vectors.json` caches
are read automatically and removed only after a valid compressed replacement
has been saved. Temporary JSON snapshots are created privately when FileTwin
needs them and removed with the scan's temporary files. Concurrent scans merge
cache updates under an account-local lock. See
[cache format and validation](docs/SIMILARITY_VECTOR_CACHE.md) and
[resource defaults and future scheduling work](docs/SIMILARITY_RESOURCE_PLAN.md).

Workers are a shared limit for fetching, reading/hashing and analysis. These
stages overlap; plain text is processed concurrently too. Only metadata waits
in the discovery queue, and an original is fetched when a processing slot is
available. Identical files share an in-flight result without blocking unrelated
work. Native readers can borrow unused memory within the scan allowance for
larger files. Progress shows the actual phase counts and any memory/reuse waits.
See the [pipeline investigation and implementation](docs/SIMILARITY_CONCURRENCY_PLAN.md).

The imported source and component notices are in
[`vendor/FileTwin`](vendor/FileTwin/IMPORT.md). FFmpeg is installed separately;
its redistribution terms depend on the selected build.

## Credentials and local data

Application client configuration is supplied through
`.local/pikpak-client-credentials.json` or the build environment and included in
the generated app. Account login data is created and managed automatically by
the app under:

```text
~/Library/Application Support/My PikPak for Mac/
```

The legacy folder name and `com.wky.PikPakDownloader` bundle identifier are
retained for upgrade compatibility. iCloud connection bookmarks live in the
app's preferences. Native similarity catalogs are separated under
`Similarity/Native/icloud`, `Similarity/Native/photos` and `Similarity/Native/local`.
Similarity-original buffers are released after each file. Originals handed
to another app are kept in the private `OpenFiles` cache so they survive exit.

The app stores its desktop session with owner-only file permissions. Session
files are plaintext and readable by processes running as your macOS user. The
login window uses a disposable Web session; it does not import Safari's cookies
or saved credentials.

All windows share the selected PikPak account and its token-refresh lock.
Switching accounts changes the shared session; saved transfers remain separated
by verified account. New windows use the primary state locations and do not
create session directories. On restoring an account, unfinished queues from old
`Transfers/Sessions/<session>` directories are imported once into its shared
queue, with upload journals and partial-file ownership preserved. Atomic import
receipts prevent completed work from returning on another launch. Legacy files
remain intact for recovery; imported queues wait for an explicit resume.

Do not commit account records, tokens, device IDs, private share links, request
files, logs, screenshots containing private data, or build artifacts. The
ignore rules cover common local paths; they do not sanitize arbitrary files or
remove data already committed to Git. Review `git status` and the staged diff
before pushing. Only placeholder configuration templates belong in Git.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| `swiftc` or the macOS SDK is missing | Install/update Apple's developer tools and check `xcode-select -p`. |
| `cargo` is not found | Finish the Rust installation, then reopen Terminal so its PATH changes take effect. |
| Client credentials are missing or invalid | Check that the local file is valid JSON and both values are nonempty. It belongs in `.local/`; `.env` is not loaded by the build helper. |
| Architecture mismatch | Check for an ARM Rust host and an `arm64` Terminal session. The app script targets Apple Silicon only. |
| The UI looks like an older version | Quit other copies, launch from `~/Applications`, and archive loose backup apps using the helper above. |
| The app requests sign-in again | Sign in through Settings → Accounts; the app saves the new session automatically. No manual token or build configuration changes are needed. |
| A cloud operation fails | Open the footer's status details. Account limits, connectivity, and PikPak API changes can affect operations. |

## Development

| Path | Contents |
| --- | --- |
| [`macos/`](macos/) | SwiftUI/AppKit interface, account storage, previews, and file interactions. |
| [`src/`](src/) | Rust API client, transfer engine, and CLI. |
| [`scripts/`](scripts/) | Build scripts, regression tests, and synthetic UI fixtures. |
| [`macos/Info.plist`](macos/Info.plist) | App identity, deployment version, and displayed version/build number. |
| `target/`, `dist/`, `.local/` | Ignored build output and private machine configuration. |

Run the Rust tests without a live account:

```sh
cargo test --locked
```

See [Testing](docs/TESTING.md) for native model tests and UI fixtures. The engine
also provides a CLI; list its commands without signing in:

```sh
cargo run --locked -- --help
```

Authenticated CLI use needs its own token configuration. The app manages its
session through **Settings → Accounts**. For Cargo commands that should embed
the configured application credentials, use the same build helper:

```sh
python3 scripts/with-client-credentials.py cargo build --release --locked
```

The app icon is already included. Only after changing its artwork, run
`./scripts/build-app-icon.sh` before rebuilding the app.

## License and upstream

[MIT License](LICENSE). The Rust client and original CLI are based on
[youming-ai/pikpak-downloader](https://github.com/youming-ai/pikpak-downloader).
The original license and copyright attribution are retained.
