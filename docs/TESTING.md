# Testing MyCloudDriver

Run commands from the repository root. The Rust and native model tests below
use synthetic data, temporary files, or local HTTP fixtures. They do not need a
PikPak account or the private build credentials.

## Rust engine

```sh
cargo test --locked
```

This covers the library and CLI, including authentication request handling,
uploads, resumable downloads, shared links, and file undo behavior.

## Native app model tests

These commands use **zsh**. They compile the production Swift sources with
`FINDER_WORKSPACE_TESTS`, exclude the real app entry point, and add one test
entry point. The executable has no bundled PikPak engine.

For Browser/Links selection and batch-save regressions:

```zsh
test_output="$(mktemp -d)"
./scripts/build-native-test.sh scripts/SharedLinkSelectionTests.swift \
  "$test_output/shared-link-selection-tests"

"$test_output/shared-link-selection-tests"
```

The helper also compiles the C archive reader and links macOS `libarchive.2`.
Use the same helper with one of these entry points to test another
area. Compile **one entry point at a time**; each declares `@main`.

| Entry point in `scripts/` | Coverage |
| --- | --- |
| `NativeDriveTests.swift` | iCloud path boundaries, copying/rollback, cleanup revalidation, Undo/Redo, folder merge, Photos membership planning, search cancellation, concurrent native scans and Photos staging cleanup. Pass the built app's Resources path to include real engine scans. |
| `FinderWorkspaceTests.swift` | Settings, resource attribution, navigation, and account management. |
| `FinderFileOpeningTests.swift` | File handoff, Open With, Quick Look loading, navigation, and cancellation. |
| `FinderFileUndoTests.swift` | Undo/Redo history, partial completion, upload batches, and account isolation. |
| `WorkspaceSwitchingTests.swift` | Tab switching, cached presentation, cancellation, and performance. |
| `SharedLinkSelectionTests.swift` | Selection across links, recursive roots, batch saving, and download routing. |
| `SharedLinkRetryTests.swift` | Batch retries, concurrency limits, saved access codes, selection preservation, cancellation, and selection regressions. |
| `TaskActivityTests.swift` | File-menu tasks, footer progress, results, and account-scoped updates. |
| `SimilarityTests.swift` | 5% minimum score, upstream raw counters, real saved-score row queries, tree identity, score precision, unmatched/skipped files, source isolation, cancellation and cleanup. Pass the built app's `Contents/Resources` path as its first argument. |

Other test files may require different flags, companion fixture engines, or a
smaller source list. Read their entry points before running them.

## FileTwin content similarity

The cloud regression suite uses a local HTTP server and synthetic OAuth replies.
It checks paginated listings, overlapping selections, unrestricted file sizes,
hidden files, raw file/candidate-pair counters, saved per-file scores after originals are removed, path traversal protection, cloud result mapping, and
cancellation of a stalled request. It never contacts PikPak:

```sh
cargo test --locked --lib similarity::tests
```

After building the app, verify the actual bundled model, worker and native
libraries. This creates synthetic TXT, DOCX, PDF, PNG, WAV and MP4 files and
scans them without an account. FFmpeg 9 and ffprobe 9 must be installed:

```sh
python3 scripts/test-similarity-native.py \
  --resources 'dist/MyCloudDriver.app/Contents/Resources'
```

Compile `scripts/SimilarityTests.swift` with the native model test command above,
then run it with the **absolute** `Contents/Resources` path. It launches the real
local scanner from a private temporary directory; it uses no saved account.
The imported FileTwin source includes its upstream Rust tests. Run them after
changes to the core using `cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core`.
`vendor/FileTwin/UPSTREAM-SHA256.json` records the original imported source
checksums and upstream revision; `vendor/FileTwin/IMPORT.md` documents the integration.

`SimilarityUITestApp.swift` renders the production outline and similarity pane
with synthetic files, saved score rows, thumbnails and skipped-file outcomes.
Verify folder expansion/search, file selection, the 5–100% saved-score filter,
identical-only filtering, Preview/Open controls and Quick Look arrow navigation.
The Fixture menu offers minimum window size, dark/light appearance, and raw pair
progress. The displayed files and previews belong to its private temporary
folder; it never loads real account sessions or the user's Photos library.

Saved-score tests must include a scan with originals subsequently removed:
queries must still work, self scores must be omitted, each score must belong to
the selected file, and missing/incompatible scores must not be reported as zero.
Native provider tests additionally verify Photos asset IDs are mapped back from
FileTwin IDs after staging copies have been removed.

## Focused layout test

The multi-drive suite uses temporary folders and a simulated Photos provider;
it never authorizes PhotoKit or alters a live library:

```sh
./scripts/build-native-test.sh scripts/NativeDriveTests.swift /tmp/native-drive-tests
/tmp/native-drive-tests "$PWD/dist/MyCloudDriver.app/Contents/Resources"
python3 scripts/test-drive-archive.py
```

`NativeDriveUITestApp.swift` displays the production home screen, drive switcher,
iCloud browser, Photos grid, settings and activity footer with synthetic files.
Use its Fixture menu to switch appearance, resize to the minimum window size
and show scan progress. Check that changing drives preserves each selection and
does not stop the synthetic activity. Do not grant access to a real Photos
library as part of the fixture test.

The archive suite checks normal/encrypted ZIPs, password retries, Unicode names,
streaming progress, cancellation, links and traversal rejection. Native archive
formats depend on macOS's libarchive build; unsupported encryption is reported.

### Other focused layouts

Check the shared-link input layout without compiling the full app:

```sh
test_output="$(mktemp -d)"
swiftc -swift-version 5 -parse-as-library \
  macos/SharedLinkInputBar.swift \
  scripts/SharedLinkInputTests.swift \
  -o "$test_output/shared-link-input-tests"
"$test_output/shared-link-input-tests"
```

## Native UI fixtures

Files named `*UITestApp.swift` are interactive test apps. For example,
`SharedLinkSelectionUITestApp.swift` presents the production Links interface
with synthetic shares and in-memory saves. `FileUndoUITestApp.swift` supplies
synthetic actions for the Edit menu and keyboard shortcuts.
`SharedLinkRetryUITestApp.swift` adds failed links with delayed local responses
to check the batch retry button, progress, and completion results.

For these fixtures, use the full source list and `FINDER_WORKSPACE_TESTS`
flag above, replacing the test entry point with the fixture app. A fixture
needs its own `.app` wrapper with matching executable metadata and a **distinct
bundle identifier**. Keep it under ignored `dist/`, and do not bundle the
production PikPak engine, private client configuration, or account data. Other
fixtures may need the companion engine or Info.plist described in their source.

Use synthetic fixtures for screenshots. Real account names, private share URLs,
tokens, and user files must stay out of repository artifacts.

## Release build check

After configuring local credentials as described in the
[README](../README.md#3-provide-application-configuration-for-the-build):

```sh
./scripts/build-app.sh
codesign --verify --deep --strict "dist/My PikPak for Mac.app"
```

Before publishing, check the staged files as well as the build:

```sh
git diff --check
git status --short
git diff --cached --stat
```

`.gitignore` excludes normal runtime data and build output. It cannot detect
credentials pasted into source; run a secret scan when changing authentication,
local configuration, or publication workflows.
