# MyCloudDriver

A native macOS app for managing PikPak cloud files, shared links, uploads, and
downloads. The repository is named **MyCloudDriver**; the installed app is named
**My PikPak for Mac**.

The interface uses SwiftUI and AppKit, with a bundled Rust engine for cloud
operations. This is an unofficial client and requires your own PikPak account.
Changes to PikPak's API can affect functionality.

To use a built app, sign in through **Settings → Accounts**. The app obtains,
verifies, and saves your account session automatically. You do not need to copy
tokens, create an `.env` file, or configure account credentials manually.

[Features](#features) · [Build the app](#build-the-app) ·
[First use](#first-use) · [Troubleshooting](#troubleshooting) ·
[Development](#development)

## Features

| Area | What you can do |
| --- | --- |
| **Browser** | Browse in List or Thumbnails, search, select multiple items, rename, move, create folders, and move items to Trash. |
| **Transfers** | Queue uploads and downloads, change worker limits, monitor progress, and pause, resume, or retry supported transfers. |
| **Links** | Open multiple shared links, select items across expanded links, save selections to your PikPak, and queue downloads. |
| **Accounts** | Sign in, check login status, add accounts, switch accounts, and log out from Settings. |
| **Maintenance** | Check for duplicates, remove empty folders or `.DS_Store` files, and merge selected folders through the File menu. |
| **Similarity** | Find similar documents, images, audio and video using FileTwin, with separate cloud and local scans. |
| **Status** | Follow background activity in the footer; open its status control for progress, results, and available actions. |

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
  content and review grouped matches. Closing the window keeps the scan running;
  reopen it from the status footer. Nothing is deleted automatically.
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
compiles the native interface, bundles the model, ONNX Runtime, PDFium and
notices, injects the local client configuration, and applies an ad-hoc signature.
The completed app is:

```text
dist/My PikPak for Mac.app
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

1. Quit any running copy of **My PikPak for Mac** after its active work finishes.
2. In Finder, copy `dist/My PikPak for Mac.app` into `~/Applications`. Create
   that folder if necessary; choose **Replace** when updating an existing copy.
3. Launch the app from `~/Applications`.

You can launch that installed copy from Terminal:

```sh
open "$HOME/Applications/My PikPak for Mac.app"
```

Keep rollback copies as ZIP archives. Loose backup `.app` bundles share the
same app identity, and macOS launchers can open an older copy by mistake.
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

1. Sign in when prompted, or open **Settings → Accounts**. Complete sign-in on
   PikPak's page in the app's login window. The app verifies your account and
   saves its session automatically for future launches.
2. Use **Browser** to navigate your folders. Choose **View → as List** or
   **View → as Thumbnails** to change the display.
3. Select items and choose **Add Selected Items to Download Queue**. Open
   **Transfers**, check the download destination, and start the download.
4. To upload, drag files from Finder onto a destination folder, or use
   **File → Upload Files or Folders…**.
5. In **Links**, add a share URL and an access code if needed. Expand the link,
   select its files or folders, and right-click to save or download them.

Settings also contains transfer worker limits and Resources, which shows
resource usage and the background tasks responsible for it. Maintenance
commands are in **File**; progress and results appear in the footer's status
control.

### Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
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
3. Choose content types and a minimum score. Higher values require closer
   matches. **Include byte-identical copies** also checks SHA-256 for every
   included file type, including formats without a similarity decoder.
4. Start the scan. Browsing, transfers and other background tasks remain
   available. Each source has its own progress and Cancel action in the footer
   and its own entry in **Settings → Resources**.
5. Review groups with the **All**, **Similar**, or **Identical** filter. Open a
   file in its default app, reveal local files in Finder, inspect coverage and
   skipped items, or export the displayed results as JSON.

Cloud analysis reads actual file content by downloading temporary copies. The
defaults are **10 GiB per cloud scan** and **1 GiB per file**; change them in
**Scan Options** before starting. Received bytes count toward the budget even
if a download fails. Temporary copies are removed on completion or cancellation.
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

Unsupported, unreadable, changing, hidden or oversized files are reported as
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
