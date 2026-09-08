# MyCloudDriver

A native macOS app for managing PikPak cloud files, shared links, uploads, and
downloads. The repository is named **MyCloudDriver**; the installed app is named
**My PikPak for Mac**.

The interface uses SwiftUI and AppKit, with a bundled Rust engine for cloud
operations. This is an unofficial client and requires your own PikPak account.
Changes to PikPak's API can affect functionality.

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
- **Background extraction:** extract supported cloud archives while continuing
  to use the app. Password-protected archives prompt for a password; progress
  appears in the status area.
- **Undo and Redo:** reverse supported Trash, move, upload, rename, and new-folder
  actions. History lasts for the current account's app session. Cleanup tools,
  share imports, and extractions are outside this history.

## Build the app

### 1. Install the prerequisites

The current build script targets **Apple Silicon Macs (`arm64`)** and sets
**macOS 13.0** as the deployment target. It does not create an Intel or universal
app. Build on an Apple Silicon Mac with a native ARM Rust toolchain.

| Requirement | Setup |
| --- | --- |
| Apple developer tools | Install Xcode or the Command Line Tools from [Apple](https://developer.apple.com/xcode/resources/). The build needs `swiftc`, a macOS SDK, and `codesign`. |
| Rust and Cargo | Install the stable toolchain using the [official Rust instructions](https://rust-lang.org/tools/install/). |
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
language mode, Rust/Cargo 1.94.1, and Python 3.9.6.

### 2. Clone the repository

```sh
git clone https://github.com/wkyle251/MyCloudDriver.git
cd MyCloudDriver
```

Access to this private repository requires an authorized GitHub account. Run
the remaining commands from the repository root.

### 3. Configure local client credentials

The app needs two OAuth **application client secrets**, which are excluded from
Git. Obtain the matching Web and desktop client secrets from the project
maintainer through a private channel. These fields do not take your account
password or refresh token; you sign in to your account in the app after building.

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

```sh
./scripts/build-app.sh
```

The script builds the Rust engine with `cargo build --release --locked`,
compiles the native interface, bundles the engine and icon, injects the local
client configuration, and applies an ad-hoc signature. The completed app is:

```text
dist/My PikPak for Mac.app
```

No Xcode project or workspace file is needed: the script invokes the compilers
directly. The finished app includes its Rust engine, so end users do not need
Rust, Cargo, or Python installed to run it.

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
   PikPak's page in the app's login window.
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

## Credentials and local data

Build credentials stay in `.local/pikpak-client-credentials.json` or the build
environment. Account login data is managed separately by the app under:

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
| The app requests sign-in again | Check the current account in Settings → Accounts. Account sessions are separate from build credentials. |
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
