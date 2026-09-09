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
test_sources=(macos/*.swift)
test_sources=("${(@)test_sources:#macos/PikPakDownloaderApp.swift}")
test_output="$(mktemp -d)"

swiftc \
  -D FINDER_WORKSPACE_TESTS \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -parse-as-library \
  "${test_sources[@]}" \
  scripts/SharedLinkSelectionTests.swift \
  -o "$test_output/shared-link-selection-tests"

"$test_output/shared-link-selection-tests"
```

Use the same compiler options with one of these entry points to test another
area. Compile **one entry point at a time**; each declares `@main`.

| Entry point in `scripts/` | Coverage |
| --- | --- |
| `FinderWorkspaceTests.swift` | Settings, resource attribution, navigation, and account management. |
| `FinderFileOpeningTests.swift` | File handoff, Open With, Quick Look loading, navigation, and cancellation. |
| `FinderFileUndoTests.swift` | Undo/Redo history, partial completion, upload batches, and account isolation. |
| `WorkspaceSwitchingTests.swift` | Tab switching, cached presentation, cancellation, and performance. |
| `SharedLinkSelectionTests.swift` | Selection across links, recursive roots, batch saving, and download routing. |
| `SharedLinkRetryTests.swift` | Batch retries, concurrency limits, saved access codes, selection preservation, cancellation, and selection regressions. |
| `TaskActivityTests.swift` | File-menu tasks, footer progress, results, and account-scoped updates. |
| `SimilarityTests.swift` | Integer limits, independent sources, a real local scan and cancellation, streamed progress, report decoding, and temporary cleanup. Pass the built app's `Contents/Resources` path as its first argument. |

Other test files may require different flags, companion fixture engines, or a
smaller source list. Read their entry points before running them.

## FileTwin content similarity

The cloud regression suite uses a local HTTP server and synthetic OAuth replies.
It checks paginated listings, overlapping selections, download limits, hidden
and oversized files, path traversal protection, cloud result mapping, and
cancellation of a stalled request. It never contacts PikPak:

```sh
cargo test --locked --lib similarity::tests
```

After building the app, verify the actual bundled model, worker and native
libraries. This creates synthetic TXT, DOCX, PDF, PNG, WAV and MP4 files and
scans them without an account. FFmpeg 9 and ffprobe 9 must be installed:

```sh
python3 scripts/test-similarity-native.py \
  --resources 'dist/My PikPak for Mac.app/Contents/Resources'
```

Compile `scripts/SimilarityTests.swift` with the native model test command above,
then run it with the **absolute** `Contents/Resources` path. It launches the real
local scanner from a private temporary directory; it uses no saved account.
The imported FileTwin source is unchanged and includes its upstream Rust tests.
`vendor/FileTwin/UPSTREAM-SHA256.json` records the imported source checksums.

`SimilarityUITestApp.swift` renders the production review window with synthetic
documents, image groups and skipped files. Verify the two source tabs, all three
result filters, selection, coverage sheet, integer-only limits, and both small
and large window sizes. Changing options should keep the **Last scan** scope
and threshold attached to existing results until a new scan begins.

## Focused layout test

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
