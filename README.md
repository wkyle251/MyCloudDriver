# MyCloudDriver

A native macOS app for **PikPak, iCloud Drive and Apple Photos**. Choose a drive
on the home screen, then browse, organise, preview and compare its content in a
consistent workspace. The repository and installed app are named **MyCloudDriver**.

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

## Features

| Area | What you can do |
| --- | --- |
| **Drives** | Start with PikPak, iCloud Drive or Apple Photos; use All Drives or the header switcher to change workspace without stopping background work. |
| **Browser** | Browse in List or Thumbnails, search, select multiple items, rename, move, create folders, and move items to Trash. |
| **Transfers** | Queue uploads and downloads, change worker limits, monitor progress, and pause, resume, or retry supported transfers. |
| **Links** | Open multiple shared links, select items across expanded links, save selections to your PikPak, and queue downloads. |
| **Accounts** | Sign in, check login status, add accounts, switch accounts, and log out from Settings. |
| **Maintenance** | Check for duplicates, remove empty folders or `.DS_Store` files, and merge selected folders through the File menu. |
| **Similarity** | Browse a scanned file tree, select a reference file, and review individual similarity scores, previews and identical copies. Filter saved scores from 5% without rescanning. |
| **Status** | Follow background activity in the footer; open its status control for progress, results, and available actions. |

### Provider support

| Function | PikPak | iCloud Drive | Apple Photos |
| --- | --- | --- | --- |
| Browse, search, list/grid, multi-select | Files and folders | Files and folders | Photos, videos and albums |
| Open With and Space Quick Look | Downloads a copy | Downloads cloud-only files as needed | Fetches original media as needed |
| Import / export | Upload / download queues | Copy into / out of the connected folder | Import media / export originals |
| Organise | Create, rename, move, copy, Trash | Create, rename, move, copy, Finder Trash | Create/rename albums, add/move album membership, delete |
| Duplicate and similarity scans | Cloud or separate This Mac scope | Selected items or current folder | Selected media, albums or library |
| Cleanup and merge | Folder maintenance | Folder maintenance | Empty albums and album merging |
| Archive extraction | PikPak's cloud extractor | Background extraction using macOS libarchive | Not applicable to a photo library |
| Shared links | PikPak links | Not applicable | Not applicable |

Photos uses the system photo library through PhotoKit. It does not expose
arbitrary filename renaming or programmatic undelete. Album edits and membership
changes have Undo; deleted media is restored in **Photos → Recently Deleted**.
Opening or exporting produces the original still image or video, not a Photos
editing session; a Live Photo's paired motion resource is not exported as a
separate video. Photos edits are managed in Apple's app.

iCloud file changes sync through macOS. Native imports and exports start
immediately, show progress and support cancellation; PikPak retains its own
pause/resume queue. iCloud rename, move, copy, Trash, cleanup, merge and extraction
support session Undo. Existing PikPak Undo coverage is described below.

- **Finder-style file actions:** right-click for **Open**, **Open With**, and
  **Other…**. Opening a cloud file fetches a local copy for the selected app.
- **Quick Look:** press Space to open a preview immediately. A loading indicator
  appears while the file is fetched; Up/Down changes the previewed item.
- **Drag and drop:** drop local files onto a cloud folder to upload them, or
  drag cloud items between folders to move them.
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
  content. Results use an expandable file tree and a ranked match pane with actual
  pair scores, paths and Preview/Open actions. Change the 5–100% minimum score
  without rescanning. Closing the window keeps the scan running;
  reopen it from the status footer. Nothing is deleted automatically.
  FileTwin reports raw file/pair counters; unknown totals use an activity indicator.
  Scores are loaded for the selected file, so the UI does not load the full matrix.
  **Export Scan Summary** exports the displayed inventory and identical-copy
  evidence; it does not export the complete score matrix. See the
  [results design](docs/SIMILARITY_RESULTS_DESIGN.md).
- **Undo and Redo:** reverse supported Trash, move, upload, rename, and new-folder
  actions. History lasts for the current account's app session. Cleanup tools,
  share imports, and extractions are outside this history.

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
`FILETWIN_MODEL_DIR` to another provisioned directory. Then build:

```sh
./scripts/build-app.sh
```

The script builds the Rust engine and FileTwin worker with locked dependencies,
compiles the native interface and C archive reader, bundles the model, ONNX Runtime, PDFium and
notices, injects the local client configuration, and applies an ad-hoc signature.
The completed app is:

```text
dist/MyCloudDriver.app
```

No Xcode project or workspace file is needed: the script invokes the compilers
directly. The finished app includes its Rust engine, so end users do not need
Rust, Cargo, or Python installed to run it.

Audio, video and HEIF/AVIF similarity also require **FFmpeg 9** and **ffprobe 9**
on the user's Mac. The app detects them in `/opt/homebrew/bin` or
`/usr/local/bin`. For Homebrew installations, use `brew install ffmpeg` and
check `ffmpeg -version`. Other file types can be scanned without them; missing
decoders are reported in scan coverage.

Image and video similarity require **macOS 14 or later**, the minimum version
of the bundled ONNX Runtime. On macOS 13 those two content toggles are disabled;
the rest of the app, document/audio similarity and byte-identical checks remain
available. This does not change the app's macOS 13 deployment target.

### 5. Install and launch

1. Quit any running copy of **MyCloudDriver** after its active work finishes.
2. In Finder, copy `dist/MyCloudDriver.app` into `~/Applications`. Create
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
2. Use **Browser** to navigate your folders. Choose **View → as List** or
   **View → as Thumbnails** to change the display.
3. In PikPak, select items and choose **Add Selected Items to Download Queue**. Open
   **Transfers**, check the download destination, and start the download.
4. In iCloud Drive or Photos, use **Import…** or drop files into the open
   location. Use **Export…** to save selected items to a folder on this Mac.
   In PikPak, use **File → Upload Files or Folders…** or drop onto a destination folder.
5. In **Links**, add a share URL and an access code if needed. Expand the link,
   select its files or folders, and right-click to save or download them.

Use **All Drives** or **Go → All Drives** to return home. Settings → Drives
manages iCloud's saved folder and Photos access. Settings also contains
transfer worker limits and Resources, which shows
resource usage and the background tasks responsible for it. Maintenance
commands are in **File**; progress and results appear in the footer's status
control.

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| All Drives | Command-Shift-H |
| Browser / Transfers / Links | Control-Command-1 / 2 / 3 |
| List / Thumbnails | Command-1 / 2 |
| Quick Look | Space; Up/Down changes the selected item |
| Close Quick Look | Space or Escape |
| Upload files or folders | Command-Shift-U |
| Add selection to download queue | Command-Option-D |
| Move selection to Trash | Command-Delete |
| Undo / Redo | Command-Z / Command-Shift-Z |
| Show status | Command-Shift-I |
| Refresh | Command-R |

## Find similar files

1. Choose **File → Find Similar Files…**.
2. In **PikPak Cloud**, use the current Browser folder or its selection. A folder
   includes descendants. In **This Mac**, choose files or folders with the file
   picker; no PikPak login is required. The two sources are never mixed.
   From iCloud Drive or Apple Photos, the same command uses that drive's current
   selection or location. Each drive keeps its own scan and results. Photos
   prepares original media privately; iCloud scans its materialized files.
3. Choose content types and a minimum score from **5% to 100%**. Higher values require closer
   matches. **Include byte-identical copies** also checks SHA-256 for every
   included file type, including formats without a similarity decoder.
4. Start the scan. Browsing, transfers and other background tasks remain
   available. The progress panel shows the current stage, completed/total work,
   current file, bytes read, elapsed time and counts. Percentages describe the
   current stage; finding files and preparing the report stay indeterminate
   until their work is known. Each source also has progress and Cancel in the
   footer and its own entry in **Settings → Resources**.
5. Review groups with the **All**, **Similar**, or **Identical** filter. Open a
   file in its default app, reveal local files in Finder, inspect coverage and
   skipped items, or export the displayed results as JSON.

Cloud analysis reads actual file content by downloading temporary copies.
There is **no per-file size limit or per-scan cloud download cap**. Copies are
streamed to disk and removed on completion or cancellation; cloud scans need
local space for the selected files. Decoder memory and result-storage bounds
still apply, and failures are included in scan coverage.
Local content stays on the Mac. New scans re-read content instead of trusting a
previous result. Results remain in the window until a new scan or app exit;
cloud results clear when changing accounts. An active cloud scan must finish or
be cancelled before switching accounts; a local scan can continue.

FileTwin supports UTF-8 text, DOCX body text, PDFs with a text layer, raster
images, and supported audio/video containers. It does not perform OCR or search
inside archives. Images use visual content; audio uses sampled sound; video
uses sampled frames, without audio or sequence order. Scores are experimental
cosine similarity, not a probability or a guarantee that files are duplicates.
Groups require every member pair to meet the cutoff.

Unsupported, unreadable, changing or excluded hidden files are reported as
skipped. Check **Coverage & Skipped Files** before treating an empty result as
exhaustive. The review/export is bounded to 2,000 groups and 20,000 members, with
up to 500 issue details; a notice appears if more results exist. Choose smaller
scopes to review remaining matches. FileTwin's private metadata/vector catalogs
are stored under the app's Application Support `Similarity` directory,
separately for each account and local scans. They can include file names and
paths; keep this directory private.

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
`Similarity/Native/icloud` and `Similarity/Native/photos`; temporary Photos
originals are removed when a scan finishes or is cancelled. Originals handed
to another app are kept in the private `OpenFiles` cache so they survive exit.

The app stores its desktop session with owner-only file permissions. Session
files are plaintext and readable by processes running as your macOS user. The
login window uses a disposable Web session; it does not import Safari's cookies
or saved credentials.

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
