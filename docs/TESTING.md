# Testing MyCloudDriver

## RAM torrent uploads (2.2.46)

The native suite covers the queue-decode compatibility guard, per-file progress
parsing, piece-safety drain logic, `reselect`, streaming uploads, RAM reclaim
and volume recycling. `queueCompatibility` must pass before any change to
`LocalTorrentJob` or `TorrentRelayState` ships: it decodes a queue written by
the shipping build, and a new **non-optional** field breaks it — Swift's
synthesised `Codable` ignores property defaults, so `load()` throws and the
user's whole saved queue is dropped. Verify a struct change by adding a canary
field and watching the guard fail with `keyNotFound`.

```sh
cargo test --lib torrent_relay
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests --ram-volume
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --ram
```

The native tests cover batch sizing, RAM-only destinations, both pause/resume
stages, account and login-method binding, a lost cloud receipt followed by RAM
loss, restart of unfinished work and final memory release. The volume test
creates and detaches its own 256 MiB APFS RAM device; it checks case-sensitive
names, sparse boundary writes, volume reuse and denial of disk writes after
unmount. Never substitute an existing disk device.

The loopback test downloads generated torrent files directly into a real RAM
volume, pauses, recreates the app model, resumes partial pieces and compares
SHA-256 at the synthetic upload sink. Rust HTTP fixtures exercise the actual
PikPak/OSS upload path, content validation, lost responses, completed receipts
without source data, account mismatch and secret-free journals. No test sends
user files to PikPak or uses a public torrent.

## Local torrent downloads (2.2.45)

```sh
python3 scripts/prepare-torrent-engine.py
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --dht
```

Native tests cover magnet validation, file selection before payload starts,
private state, corrupt queues, destination checks, ambiguous RPC replies,
pause/resume, persisted selections and stopping during a pending start.
Metadata statistics cover changing peer/seed counts and both transfer speeds,
including zero readings and resets after queueing, pause, retry and completion.
Retry tests cover continued peer waiting, retry delay, failed retries, engine
exit recovery and cancellation through Pause and Stop without starting payloads.
The integration test generates its own three-file torrent and runs a tracker
and seeder on loopback. DHT, peer exchange and local peer discovery are disabled.
It fetches magnet metadata without payload, downloads selected files, pauses,
restarts the engine, resumes partial pieces and verifies SHA-256, unselected-file
cleanup and completion without continued seeding. It also checks live connected
peers, seeds and nonzero download speed, plus cleared statistics after pause and
completion. It contacts no public peers.

The `--dht` scenario starts with an empty routing table and a magnet containing
no trackers. A loopback DHT node answers bootstrap, node lookup and peer lookup
requests; the real aria2 peer supplies metadata and selected file contents.
The test requires nonzero connected peer/seed counts and speed during download,
then verifies pause/resume, SHA-256 and completion. No public DHT is contacted.

Run the native binary with `--ui` to inspect the production local-torrent views
using a synthetic 7,105-file manifest. Load a fixture magnet or `.torrent` file;
its engine is a mock and makes no network requests. Also exercise the Cloud
Downloads file-limit fixture and its **Download to Mac** handoff.

## PikPak management workspaces (2.2.41)

```sh
cargo test --lib management::tests --locked
./scripts/build-native-test.sh scripts/PikPakManagementTests.swift /tmp/mycloud-management-tests
/tmp/mycloud-management-tests
```

HTTP fixtures cover account ownership in all three content modes, task/share
request shapes, creation without ambiguous retries, Trash restoration preflight,
PAT deletion restrictions, OAuth deletion/empty confirmation, input validation,
and metadata redaction. Native tests cover pagination/deduplication, repeated
page tokens, mismatched accounts, delayed replies after switching, mutation
failures, expiry/permissions, and existing mode/token-connection behavior.
Cloud-task regressions cover the exact `task_sub_task_num_limit` reply, unrelated
416 responses, nested provider dialog text, redaction, definite vs uncertain
creation failures, repeated rejected torrents, a replacement source, and stale
failures after account switching.

Run the same native binary with `--ui` for a production-view fixture containing
cloud tasks, shares and Trash. Its API callbacks only return synthetic data.
See [PikPak management](PIKPAK_MANAGEMENT.md) for live verification limits.
Use `--ui --task-limit` or `--ui --task-uncertain` to exercise the new-task error
panels with synthetic replies; submitting in these fixtures never creates a live
PikPak task.

## Personal Access Token connections

`cargo test personal_access_token` covers direct bearer authentication, account
identity, rejection without OAuth retries, private token files, the three content
modes, share-link isolation, disk downloads and similarity downloads to RAM.

```sh
./scripts/build-native-test.sh scripts/PersonalAccessTokenTests.swift /tmp/pikpak-pat-tests
/tmp/pikpak-pat-tests
```

Native checks cover secure parsing/storage, failed/cancelled/wrong-account
replacement, successful persistence, helper isolation and existing account and
content-mode behavior. `scripts/PersonalAccessTokenUITestApp.swift` hosts the
production connection screen with a callback that makes no verification requests.

Run commands from the repository root. The Rust and native model tests below
use synthetic data, temporary files, or local HTTP fixtures. They do not need a
PikPak account or the private build credentials.

## Rust engine

```sh
cargo test --locked
```

This covers the library and CLI, including authentication request handling,
uploads, resumable downloads, shared links, and file undo behavior.

User/Guest/Dynamic content routing (2.2.39):

```sh
python3 scripts/with-client-credentials.py cargo test --locked content_mode
python3 scripts/with-client-credentials.py cargo test --locked guest_
./scripts/build-native-test.sh scripts/GuestModeTests.swift /tmp/mycloud-guest-tests
/tmp/mycloud-guest-tests
```

These use local HTTP fixtures and isolated preferences. They verify guest
identity checks, strict Guest behavior, per-file Dynamic fallback, disk/RAM
retries, resumed files, older queues, migration, preview invalidation and the
shared mode preference. `GuestModeUITestApp.swift` presents the production sidebar
chooser without an account. See [Download modes](PIKPAK_GUEST_MODE.md) for behavior
and when changes take effect.

Immediate per-file analysis persistence and interrupted cloud scans:

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib similarity::source_cache::
```

The local HTTP fixture checks durable text vectors and complete archive hashes
while another original is stalled, cancellation, resume with only the unfinished
file fetched, and a fresh scan with zero original GETs after clearing its
temporary checkpoint. It also retains unsupported counts and exact-copy archive
groups. Storage-failure injection prevents a failed cache write from producing
a successful scan. No real account or running scan is touched.

## Native app model tests

### Links folder navigation (2.2.38)

Links keeps each ready share's header and contents visible. Headers have no
expand/collapse action in List or Thumbnails; old saved link-collapse preferences
are ignored. Real folder disclosures still expand/collapse inline.

Opening a folder by double-click or Return shows that folder in the same
contents view as Browser, with Back, breadcrumbs, List/Thumbnails, pagination,
keyboard selection and preview. Returning to the link root restores the combined
Links list, its folder disclosures, selection and scroll target. Shared-folder
rows keep the correct Save to PikPak/download authorization, and folder-scoped
selection/search excludes other link sections.

```zsh
./scripts/build-native-test.sh scripts/SharedLinkNavigationTests.swift /tmp/mycloud-links-navigation-tests
/tmp/mycloud-links-navigation-tests
```

This suite covers nested navigation, Back/breadcrumb restoration, view identity,
per-link/account state, empty folders, real shared-page decoding and pagination.
It also runs the existing Links multi-selection and folder-thumbnail integration
checks. `SharedLinkNavigationUITestApp.swift` exposes two synthetic shares in
the production UI. Verify both have no header disclosure, folder disclosures
still work, double-click/Return opens a folder, Back/root breadcrumbs restore
the overview, and List/Thumbnails changes only the Links view preference.
No account credentials or cloud data are required.

### Folder thumbnail prefetch (2.2.37)

Clicking a file in PikPak Browser or Links warms the available thumbnails of
its direct siblings, including later folder pages. Grid tiles and image/video
preview artwork use the same cache and in-flight request. This reads thumbnail
URLs from the listing; it never resolves or downloads neighboring originals.

```zsh
./scripts/build-native-test.sh scripts/FolderThumbnailTests.swift /tmp/mycloud-thumbnail-tests
/tmp/mycloud-thumbnail-tests
```

The suite covers duplicate request coalescing, cancellation races, foreground
priority, memory eviction, failed-image cooldown, nested parents, paginated
folders, repeated page tokens, proxy routes and distinct shares with identical
file IDs. A URLProtocol fixture exercises the real URLSession download/decode
path with image, HTTP-error and corrupt-image responses. Existing Links
selection tests run in the same suite. No credentials or external network are
used. `ImagePreviewTests.swift` checks that thumbnail/original transitions still
retain the current image and reject stale completions.

The shared pool allows eight transfers, reserving two slots from background
prefetch for visible images. Connections are reused, image decoding runs off
the main thread with a 512-pixel bound, transfers have a 30-second deadline
and an 8-MiB size cap, and the decoded cache is limited to 96 MiB/1,024 images.
HTTP response caching is in memory. Missing thumbnails retain their file icons.
Changing folders, links or accounts cancels obsolete prefetch; completed images
remain reusable within the cache budget. No separate byte-range requests are
made for small thumbnails.

`FolderThumbnailUITestApp.swift` shows production Browser/Links with generated
images and delayed local completions. Start in List, click Photo 01, and expect
24 completed thumbnail requests (12 visible plus 12 on the next page). Clicking
Photo 02 or switching Browser to Thumbnails must not add requests. Each of the
two synthetic links should load its own 24 images. The selected image and
visible grid should remain responsive while prefetch is running.

The simulated 60-ms-per-image benchmark completed 24 images in 1.49 seconds
serially and 0.26 seconds with six prefetch requests in flight; these are local
scheduler measurements, not a claim about PikPak CDN throughput.

### Running other native suites

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
| `PikPakTransferQuotaTests.swift` | Monthly counters, overages, missing values, minute refresh/deduplication, manual retry, stale snapshots, cancellation and late replies after account changes. Pass a compiled `PikPakAccountVerifierFixture.swift` executable to also check the real quota helper. `PikPakTransferQuotaUITestApp.swift` presents the production sidebar and quota panel with synthetic over-limit, failed-refresh and missing-counter states. |
| `LocalDiskWorkspaceTests.swift` | Four-drive Browser entry, local folder/volume selection, symlink/root boundaries, and Show in Folder routing that opens and selects the original local or PikPak file. |
| `SimilaritySessionTests.swift` | Separate four-drive scan scopes/results; Home → Scan drive discovers paused cloud/native scans with saved RAM/time settings, fresh ownership claims and account isolation; status dismissal/window close retain state; explicit Clear cancels and cleans up without late results. |
| `SimilarityFileActionTests.swift` | Original-provider Trash routing for all four drives; Keep Smallest groups/batches, ties, overlap, retained-file checks, partial acknowledgements, duplicate clicks, stale sessions and one-step Undo/Redo. Real Trash tests restore only synthetic local files. Uses synthetic accounts/assets only. |
| `SimilarityScopePickerTests.swift` | Direct folder selection, paging/deduplication, ancestor routes, loading and access errors, stale replies, close cancellation, and iCloud scan scope independent of Browser. |
| `NativeDriveTests.swift` | iCloud path boundaries, copying/rollback, cleanup revalidation, Undo/Redo, folder merge, Photos membership planning, search cancellation, concurrent native scans and Photos staging cleanup. A delayed provider withholds its second file until the first is analysed, proving discovery and analysis overlap. Pass the built app's Resources path to include real engine scans. |
| `NativeDriveTreeTests.swift` | Inline disclosure, nested keyboard/range selection, lazy loading and cache reuse, pagination/retry, sorting during I/O, bounded concurrency, refresh after rename/move/Undo, overlapping selections, Photos row identity and cancellation. |
| `FinderWorkspaceTests.swift` | Settings, CPU/resource attribution, GPU counter validity and live device readings, navigation, and account management. CoreML job counts are attributed once per task. |
| `WorkspaceSessionTests.swift` | Eight simultaneous views of one session; shared account/navigation/queues, unchanged frames, deduplicated resource activity, original/middle-window close without teardown, scan-only browser recovery, focused file commands, stale-registration protection and exactly one final teardown. Runs without presenting browser windows. |
| `SimilarityLifecycleTests.swift` | Real helpers with isolated synthetic files: closing the browser keeps analysis running, scan windows retain account/storage ownership, result reveal reopens the same browser, Pause freezes active time, Quit saves it, and a fresh coordinator resumes without fetching completed originals. Also covers legacy descriptors and cumulative report time. Pass the app's `Contents/Resources` directory when running. |
| `WorkspaceAccountIsolationTests.swift` | Legacy per-window account/storage formats, refresh locks only for the same account, account switching and account-management regressions. These synthetic legacy models are not created by New Window. |
| `TransferPersistenceTests.swift` | Separate-process restore, once-per-account migration of old window queues, deduplicated imports, copied upload journals, import receipts that prevent completed-work resurrection, private permissions and preservation of corrupt/symlink state. |
| `TransferControlTests.swift` | Active/queued pause and cancellation, automatic retry, persisted cancellation of large-folder children, output ownership and cross-session cleanup, writer-close ordering, real local-copy interruption and preservation of original/completed files. |
| `NativeTransferFairnessTests.swift` | Paused/retrying transfers release worker slots, resume reacquires a slot, healthy transfers and other file actions proceed, rapid controls do not leak permits, and more paused filesystem workers than CPU cores leave Swift actors responsive. |
| `SimilarityResourceTests.swift` | Hardware-derived defaults, CPU/GPU distinction, custom integer bounds and serialization, memory admission, immutable scan snapshots and consistent memory units. Also compiles directly with `macos/SimilarityResources.swift`. |
| `DownloadRetryTests.swift` | Live queue admission across destinations and shared links, incremental totals, source IDs, durable acknowledgements, helper-exit races, pause/resume, retries and per-file network rates. |
| `PreviewLayoutTests.swift` | Full pane width, height-only resizing, reachable bottom handle, right-side detail reservation, compact Bottom metadata popover geometry, small windows and invalid saved heights. Also compiles directly with `macos/FinderPreviewPane.swift`. |
| `MediaPlaybackTests.swift` | Real AVFoundation playback, seeks/replay, stale callbacks after file switches, persistent volume/mute/speed, buffer gaps/overlaps and duration bounds, invalid preferences and observer teardown. Compile with `macos/MediaPlayback.swift`. |
| `NativeMediaPreviewTests.swift` | Native original preparation progress, cancellation/late completion, reuse across layout changes, retryable errors and safe staging cleanup. |
| `ExternalDiskTests.swift` | Creates its own 64 MB disk image: direct preview/export/upload sources, saved volume identity, ejection notifications, offline bookmark restoration without auto-mounting, read-only remount, incomplete-copy cleanup and replacement-disk rejection. Never uploads to a cloud account or ejects an existing user disk. Add `-D BROWSER_DROP_TESTS` to include uploader admission/resume checks. |
| `FinderFileOpeningTests.swift` | File handoff, Open With, Quick Look loading, navigation, and cancellation. |
| `FinderFileUndoTests.swift` | Undo/Redo history, partial completion, upload batches, and account isolation. |
| `WorkspaceSwitchingTests.swift` | Tab switching, cached presentation, cancellation, and performance. |
| `SharedLinkSelectionTests.swift` | Selection across links, recursive roots, batch saving, and download routing. |
| `SharedLinkRetryTests.swift` | Batch retries, concurrency limits, saved access codes, selection preservation, cancellation, and selection regressions. |
| `TaskActivityTests.swift` | File-menu tasks, footer progress, results, and account-scoped updates. |
| `SimilarityTests.swift` | 5% minimum score, upstream raw counters, real saved-score row queries, tree identity, score precision, unmatched/skipped files, source isolation, cancellation and cleanup. Also covers automatic recovery of an interrupted scan (bounded attempts, budget reset on progress, user actions ending it) and the engine `note:` filter that keeps a status line from masking a real failure. Pass the built app's `Contents/Resources` path as its first argument. |
| `SimilarityTreeExpansionTests.swift` | Expand/collapse 250 groups, visible selection after collapse, search/regroup persistence, individual toggles, repeated commands, mode switches and whole-percent cutoff values. |
| `BrowserDragDropTests.swift` | Drag targets across full rows, nested/file parents, blank space, thumbnails, clipping, scrolling, spring loading and rejection; Finder providers with native NSURL, async ordering, Unicode paths, atomic failure and root deduplication; release handoff geometry, provider capture and destination capture. Compile with `-D BROWSER_DROP_TESTS`. |
| `BrowserFolderExpansionTests.swift` | Native folder menu for 1–10/all levels with correct callbacks and fresh menu instances, cached fixed-size template icons at 1x/2x, and expansion plans covering cycles, duplicate IDs, repeated page tokens and partial-failure totals. Compile with `-D FOLDER_EXPANSION_TESTS`. |
| `CloudExtractionTests.swift` | Blocked extraction requests that explain themselves and keep the task, parallel inspection/extraction with independent progress and selection, per-archive password prompts kept in memory only, cancellation and API failures isolated to their task, bounded batch inspection, and queued password popups with wrong-password retry. Compile with `-D ARCHIVE_TASK_TESTS` and pass a built `CloudExtractionFixtureEngine` as its first argument. |
| `FileSearchTests.swift` | Search pagination, Unicode, ranking, limits, paths, navigation, cache replacement and redaction; offline local scope with duplicate link identities; transfer selection layouts and output collisions; Finder drop formats; and a live helper covering progressive root results, scope/cache isolation and cancel/reset races. Compile with `-D FILE_SEARCH_TESTS` and pass a built `FileSearchFixtureEngine` as its first argument to include the live-helper section. |
| `FolderSizeCacheTests.swift` | Exact and recursive deletion with ancestor updates and sibling preservation, overlapping multiselection, new folder/file insertion, moves across common ancestors, dirty-branch repair with clean-subtree reuse, and complete-listing reconciliation that stays safe for unknown folders. Compile with `-D FOLDER_SIZE_TESTS`. |
| `GuestModeTests.swift` | Guest Mode behaviour alongside the live download queue and retry suites. Its results appear under the download-queue PASS lines rather than its own. |
| `ICloudStorageTests.swift` | Quota parsing for personal, legacy, zero and enterprise responses plus invalid/ambiguous ones; a bounded read-only helper process covering missing commands, oversized output, timeout and cancellation; and refresh deduplication with truthful error state. Add `--live` to query the real macOS iCloud account. |
| `ImagePreviewTests.swift` | Thumbnails retained during API/full-image loading without a second empty frame, late thumbnail/original suppression and signed-URL refresh races, rapid selection changes without previous-file leakage, and bitmap/alpha/oversized/corrupt handling restricted to HTTPS sources. |
| `PikPakAccountStoreTests.swift` | Trusted-token migration into private directories without credentials in account metadata, independent device/token/lock files across sessions, duplicate sign-in replacing one account, symlink and untrusted legacy session rejection, and workspace isolation across 12 selections and 128 queue paths. |
| `PikPakAccountVerifierTests.swift` | Real helper success, expired credentials, offline failure, cancellation, process cleanup and retry. Pass a built `PikPakAccountVerifierFixture` as its first argument. |
| `PikPakTransferQuotaTests.swift` | Transfer-quota lifecycle across late replies, overlapping windows and cancellation; pass a built `PikPakAccountVerifierFixture` as its first argument to also cover the real helper's arguments, JSON delivery, failed refresh and process cleanup. |
| `PreviewTransportTests.swift` | Preview transport configuration: inherited proxies disabled and an explicit override retained. |
| `SharedLinkInputTests.swift` | One- to four-row input layouts, fields and buttons that never overlap or leave 0–1600 pt viewports including fractional widths, and bounded handling of transient zero/invalid layout proposals. |
| `SimilarityInventoryTests.swift` | Provider refresh restricted to an empty regular inventory in the owning request directory, indeterminate checking progress, skipped selected-file deletion, and a real helper catching additions/deletions/edits during and after analysis so a resumed sealed comparison never reuses scores for removed files. Pass the built app's `Contents/Resources` path as its first argument. |
| `PhotosSimilarityConcurrencyTests.swift` | Actual Swift/Rust Photos FIFO protocol with generated RAM originals: eight unknown files overlap, pause retains all provider requests, larger originals retry with increasing capacities, final contents match a known-size original byte-for-byte, oversized/invalid/truncated inputs fail without blocking healthy peers, and attempt pipes are removed. Pass the app's `Contents/Resources` path and optionally a replacement `pikpak` engine path. |
| `SimilarityProgressTests.swift` | Every progress card and queue snapshot saved on pause including late analysis completion, same-helper pause and restarts preserving cumulative totals without double counting, byte-weighted cloud progress with local/comparison fallback, and download ETA across pause/restart/stalls. |

Other test files may require different flags, companion fixture engines, or a
smaller source list. Read their entry points before running them.

A suite that names a fixture engine above needs that engine built first. Each is
a standalone entry point, so it compiles on its own rather than with the app
sources:

```zsh
test_output="$(mktemp -d)"
swiftc -swift-version 5 -parse-as-library \
  scripts/CloudExtractionFixtureEngine.swift -o "$test_output/extraction-engine"
./scripts/build-native-test.sh scripts/CloudExtractionTests.swift \
  "$test_output/cloud-extraction-tests"   # add -D ARCHIVE_TASK_TESTS, see below

"$test_output/cloud-extraction-tests" "$test_output/extraction-engine"
```

`build-native-test.sh` always defines `FINDER_WORKSPACE_TESTS`. A suite needing an
additional flag has to be compiled directly instead, keeping the same source list
the helper uses:

```zsh
sources=(macos/*.swift)
sources=("${(@)sources:#macos/PikPakDownloaderApp.swift}")
xcrun clang -target arm64-apple-macos13.0 -O2 -c macos/DriveArchive.c \
  -o "$test_output/archive.o"
swiftc -D FINDER_WORKSPACE_TESTS -D ARCHIVE_TASK_TESTS -swift-version 5 \
  -target arm64-apple-macos13.0 -parse-as-library "${sources[@]}" \
  scripts/CloudExtractionTests.swift "$test_output/archive.o" \
  -framework AVKit -larchive.2 -o "$test_output/cloud-extraction-tests"
```

Passing the wrong first argument is not always obvious: a suite expecting a
fixture engine that receives the app's `Contents/Resources` directory instead
fails with `Permission denied`, because it tries to execute a directory.

The resource-settings tests can run without compiling the app or changing saved
preferences:

```sh
swiftc -swift-version 5 -parse-as-library macos/SimilarityResources.swift \
  scripts/SimilarityResourceTests.swift -o /tmp/mycloud-similarity-resource-tests
/tmp/mycloud-similarity-resource-tests
```

The disk transport regression suite checks changed/oversized legacy partials,
strong-validator range resume, invalid Content-Range and ETag responses, HTTP 416,
interruption during legacy-prefix verification, provider cooldowns, permanent
errors, and account/shared downloads that outlive the metadata timeout:

```sh
cargo test --locked --bin pikpak -- --test-threads=1
cargo test --locked --lib download_policy
```

`DownloadRetryUITestApp.swift` displays six synthetic failures in the production
Transfers workspace. Retry All Failed must show all six selections while the
fixture holds preparation. Fixture → Show Download Progress shows two active
files with independent rates and four waiting files. Fixture → Simulate Stop,
then Retry All Failed or Resume Downloads, must retain and restart all six.
The fixture owns no real download helper and never contacts PikPak.

## FileTwin content similarity

Pause/resume verification (uses synthetic files and isolated account directories):

```sh
scripts/build-native-test.sh scripts/SimilarityResumeTests.swift /tmp/mycloud-resume-tests
/tmp/mycloud-resume-tests dist/MyCloudDriver.app/Contents/Resources
python3 scripts/test-similarity-resume.py dist/MyCloudDriver.app/Contents/Resources
```

The Swift test exercises Pause → Resume, forced helper termination, recovery in
a new session, account isolation, concurrent-window claims, temporary discovery
and acquisition failures, and Cancel cleanup. The process test pauses and kills
an in-progress comparison, removes access to the originals, and verifies every
saved pair after resuming. It also verifies helper shutdown after its GUI parent
exits. Rust checkpoint tests cover revision changes, compressed record recovery,
transaction rollback, and continued retries beyond the old attempt limit.
`SimilarityResumeUITestApp.swift` presents the production scan UI with synthetic
text files; use it to check Pause, Resume and the unfinished-scan recovery list.

The cloud regression suite uses a local HTTP server and synthetic OAuth replies.
It checks paginated listings, overlapping selections, unrestricted file sizes,
dotfiles and hidden subtrees (including explicit selections and legacy requests), FileTwin 0.2 progress and compatible-pair counters, saved per-file scores after originals are removed, path traversal protection, cloud result mapping, and
cancellation of a stalled request. It never contacts PikPak:

```sh
cargo test --locked --lib similarity
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
The Rust adapter suite also checks separate occurrences for copies and hardlinks,
128-file batch boundaries, APFS source metadata preservation, rename reuse,
same-size/timestamp edits, content-based family filtering, symlink changes,
large-file inventory, cancelled inventory, and read-only legacy score catalogs.
The native decoder smoke test repeats a scan and requires all thirteen files to
reuse vectors while still hashing their originals; both runs must remove their
temporary data without changing or growing the model directory. The UI progress fixture has
an Encoding Progress mode showing newly analysed and reused counts.

The 2.2.8 pipeline regressions additionally verify concurrent deferred original
acquisition, shared lifecycle slots, nonblocking duplicate waiters, larger-file
memory retries, cancellation during acquisition, and binary hash-only coverage.
The adapter test creates 520 unsupported files and verifies complete aggregate
counts and per-file diagnostics despite the 500-entry issue display limit.
`SimilarityTests.swift` checks separate phase counts, queue accounting for reuse
waiters and unsupported/failure totals. The Encoding Progress UI fixture shows
52 admitted files distributed across fetching, hashing, encoding and memory
waits, rather than presenting all 52 as active decoders.

The 2.2.9 fetch regressions cover HTTP 503 with Retry-After, refreshed signed
links after 403, incomplete-copy restart, permanent HTTP errors with safe
diagnostics, capped concurrent downloads, downloads exceeding metadata timeouts,
and cancellation during capacity/cooldown waits. An exhausted-retry scan must
retain the HTTP status, attempt count and fetch stage without raw URLs or bodies.
The Cloud Download Progress fixture shows actual fetches, waiting slots and
retrying files separately.

Run `python3 scripts/test-similarity-file-handles.py dist/MyCloudDriver.app/Contents/Resources`
to test the GUI launch environment. It launches disposable 60-image scans with
a 256-descriptor soft limit and then a fixed 256 hard limit. All files must
succeed: the first run keeps 52 workers after raising the helper's soft limit;
the second safely admits 10 workers. It changes limits only in its child process.

The imported FileTwin source includes its upstream Rust tests. Run them after
changes to the core using `cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core`.
`vendor/FileTwin/UPSTREAM-SHA256.json` records the original imported source
checksums and upstream revision; `vendor/FileTwin/IMPORT.md` documents the integration.

The local `encode_sources` contract tests verify that suppliers are called only
for free native slots, workers are reused, input leases are released per file,
and cancellation stops further acquisition and removes temporary originals.
The PikPak fixture separately asserts that paginated inventory downloads no
originals. `NativeDriveTests.swift` verifies a 1,005-item Photos inventory exports
nothing until one specific ID is requested, result IDs still route to the
correct provider, hidden-only scopes complete empty, and cancelling a slow
original fetch prevents the next request. `SimilaritySessionTests.swift` covers
closing inventory, stale callbacks, and request/reply path confinement.
The pipe-reader regression writes a small event while keeping the pipe open;
the event must arrive before EOF or a full read buffer. macOS Foundation's
`read(upToCount:)` can wait for the requested length, so the source handoff uses
an interruptible POSIX read on the background reader queue.

`SimilarityUITestApp.swift` renders the production outline and similarity pane
with synthetic files, saved score rows, thumbnails and skipped-file outcomes.
Verify folder expansion/search, file selection, the 5–100% saved-score filter,
group cards and weakest-pair labels, identical-only filtering, Preview/Open
controls and Quick Look arrow navigation. Change the threshold rapidly and ensure
only the latest groups appear, without changing the original scan's elapsed time.
All Files must preserve unmatched entries; All scores includes below-cutoff and
zero measurements while missing scores remain unavailable. Cancelled scans with
analysed files but no comparison run must still show their file tree.
**Show in Folder** must raise the fixture's Local Disk workspace, select the
original file and allow immediate arrow-key navigation. **Fixture → Show Results**
returns to the same results. Check Trash confirmation, cancellation, successful
result removal and the simulated failure on `Private.pdf`. The fixture only
simulates Trash responses; its UI never moves or deletes files.
The Fixture menu offers minimum window size, dark/light appearance, and raw pair
progress and cancelled inventory. The displayed files and previews belong to its private temporary
folder; it never loads real account sessions or the user's Photos library.

Saved-score tests must include a scan with originals subsequently removed:
queries must still work, self scores must be omitted, each score must belong to
the selected file, and missing/incompatible scores must not be reported as zero.
Regroup the same scan at 90%, 5% and 100% with originals removed and verify the
catalog bytes are unchanged. Include a chain A–B and B–C above cutoff with A–C
absent/below cutoff; it must not become one group. Exact hashes remain separate
evidence. Test full-precision cutoff comparisons and cancellation without partial groups.
Verify that reducing the cutoff only grows/merges groups, using mixed matrices
with missing cells, tied scores and identical hashes. Selection must follow the
same files when a selected group merges into another.
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

`NativeDriveUITestApp.swift` displays the production four-drive home screen, drive
switcher, Local Disk/iCloud browsers, Photos grid, settings and activity footer
with synthetic files. Its production session manager opens shared views through
File → New Window (Command-N); no window reads real accounts, Home files or a
Photos library. Open at least four windows; verify shared drive, folder and
selection state, and File-menu commands through the focused window. Close the
original or a middle window and create another; shared work and existing window
geometry must survive. Verify that Settings has no transfer-worker field and
that there is no Split menu. At narrow
widths the sidebar overlays from the left edge; short sidebars and Home scroll.
Fixture → Find Similar Files opens the four-drive source menu and Scan Resources
controls. Verify Automatic/Custom integer fields and Right/Bottom preview placement.
Use its Fixture menu to switch appearance, resize to the minimum window size
and show scan progress. Check that entering any drive opens Browser, preserves
its selection, and does not stop the synthetic activity. Closing a similarity
window or dismissing its completed status must clear its previous scope, filters
and results before opening another scan. Do not grant access to a real Photos
library as part of the fixture test.
Expand Documents and its Drafts subfolder with the disclosure arrows. The
location should stay at the drive root until double-click or Return opens a
folder. Check Left/Right, Up/Down and Space Quick Look on the indented files,
then expand two Photos albums to verify their separate rows and shared layout.
The Fixture menu's Show PikPak Media Preview uses a synthetic local video at
`$TMPDIR/MyCloudDriverDesignFixture/Resize sample.mp4`. Drag its bottom grip to
adjust height, then drag the browser divider and shrink the window after Use
Oversized Preview. The canvas must always fill the pane's width, with no side or
corner grip. The header, bottom handle and scrollable details must remain visible.
Settings → General → Reset Layout must restore the open workspace immediately,
including when the preview is expanded. Verify playback continues while resizing.
The media preview uses an app-owned control bar and no AVKit overlay controls.
Change volume, mute and speed; open another video and verify those choices remain.
Test seek dragging, ±10 seconds, replay, and changing speed while paused (must not
start playback). Check the 180-point minimum canvas, expanded preview and both
appearances. Native iCloud/Photos videos use this same bar; expanding their
preview must preserve playback, and switching to an image must stop the video.
PikPak's retained-byte buffer remains under Streaming details, separate from
the timeline's currently playable ranges. All UI checks use synthetic media.

Right-click a file and enter Open With. Leave the pointer on its trigger and
move between the parent and application list; the submenu must remain stable,
with application icons and Other… available. Other… must open the app chooser
and Cancel must leave the selection untouched. For a PikPak folder, hover over
Expand Folder and choose 1 Level, 2 Levels or All Levels. Test both list and
thumbnail views. Context menus explicitly use the standard button style: the
app's pointing-hand hover state must not rebuild a menu during native tracking.
PikPak folder menus use a native snapshot until dismissal. Enable **Simulate
Background Updates** in the design fixture, then keep Expand Folder open while
the status counter advances. Check Browser and Links, list and thumbnails, hover
between parent/submenu, Escape, and actual depth selection. Normal left-click
selection, disclosure and dragging must still work. The focused
`BrowserFolderExpansionUITestApp.swift` fixture also has a background-update
toggle and logs native menu changes to
`/private/tmp/myclouddriver-folder-menu-tracking.log`; a tracked native menu should
record begin/end without item rebuilds. Reopening must read current capabilities.

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
`MediaTimelineUITestApp.swift` shows the production seek control with contiguous,
discontinuous and empty buffers. Check that the buffer stays within the same
track as played content, including compact widths and dark mode; dragging and
keyboard adjustments must still work. Its volume control has no buffer layer.

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
codesign --verify --deep --strict "dist/MyCloudDriver.app"
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


## Similarity originals in RAM (2.2.10+)

The core native contract tests verify that RAM sources and local memory staging
never pass a disk-original path to a native worker; range reads work, identical
sources reuse vectors, and completion/cancellation release source references.
`similarity::memory` and fetch tests check shared reservations, cancellation,
size admission before any content request, retry cleanup and source-buffer
release. The Photos portion of `SimilarityTests.swift` streams synthetic bytes
through the same private pipe request as the app, validates zero file size,
checks cleanup, and rejects a regular file substituted for the pipe.

The 2.2.11 prefetch tests hold an analysis input while downloaders fill a bounded
RAM queue, then check that every buffer/reservation is released. Cancellation
is tested with both a full queue and blocked RAM reservations. The cloud adapter
regression uses a synthetic HTTP provider and two workers that cannot finish
until four downloads have completed; it verifies download/analysis independence,
RAM-native handoff, all 12 results and 66 comparisons. A native contract fixture
checks that a large decoder waiting for RAM cannot block a smaller ready file.
The Swift progress tests distinguish actual analysis from download and RAM waits.

For 2.2.12, `SimilarityResourceTests.swift` checks the full physical-memory
ceiling, 64 GB total/12 GB downloads/52 GB analysis, protocol round trips, saved
preference migration and invalid budget splits. RAM tests admit mixed file
sizes by bytes and reclaim excess unknown-length capacity. A synthetic HTTP
test holds the only connection's larger file at RAM admission and verifies a
smaller original still downloads. Adaptive connection tests grow past eight
after success and retain Retry-After/cancellation behavior.
RAM queue tests let two downloaders fill ten ready originals by byte budget,
independent of worker count, then verify capacity is reclaimed after analysis.
FileTwin's native contract tests verify that decoder reader copies count against the analysis
budget. Progress tests distinguish reserved GB from cumulative transfer bytes.
The real-decoder smoke test explicitly allocates original and analysis memory,
and verifies model reuse across images with different compressed sizes.

The queue-liveness regression in `similarity::prefetch::tests` connects the full
RAM queue to the real FileTwin encoder at 1 and 52 configured workers, and with
an intentionally impossible decoder-memory allowance. It checks mixed/unknown
sizes, byte-limit failures, unsupported content, reuse and release of all
buffers and reservations. An independent watchdog bounds the test. A failed
checkpoint callback must stop a full queue without waiting for a GUI cancel.
The fetch tests drop an in-flight request owning the whole download allowance
and verify that the waiting request completes, and check that retry backoff
holds neither RAM nor a connection.

```sh
python3 scripts/with-client-credentials.py cargo test --locked similarity::prefetch::tests
python3 scripts/with-client-credentials.py cargo test --locked similarity::fetch::tests
```

`python3 scripts/test-similarity-native.py --resources dist/MyCloudDriver.app/Contents/Resources`
checks the real shipped image, PDF, DOCX, audio and video readers. Every native
reader must report `input_storage: memory`. It also checks model/vector reuse,
unchanged compatible-pair totals, result queries without originals, and cleanup.
Add `--acceleration automatic` to check CoreML image/video inference alongside
CPU document/audio processing with the same fixtures and saved-result checks.
`test-similarity-file-handles.py` checks 52-worker RAM input under inherited soft
and hard descriptor ceilings. No personal cloud account or Photos permission is
needed for these fixtures.

These checks establish application content transport and lifecycle behavior;
they do not claim to suppress macOS swap or iCloud/Photos system caches. See
[Similarity originals in memory](SIMILARITY_MEMORY.md).


## CoreML and retained scans (2.2.14)

`test-similarity-acceleration.py <Resources> --output <file.json>` uses synthetic
images to compare CPU, cold CoreML and warm CoreML. It verifies the actual worker
backend, memory transport, accelerator admission, all pair scores and bounded
CPU/CoreML score differences. Timings are fixture-specific, not a speed claim
for user libraries. Host tests cover automatic fallback and checkpoint backend
pinning. The CoreML native contract test verifies CPU documents continue while
visual jobs stay in one bounded set of persistent worker processes.

`SimilarityResumeTests.swift` verifies close and Cancel retain progress, Resume
reuses completed originals, completed results survive reopening in a new model,
and Clear removes both checkpoint and result matrix while keeping originals,
including a final helper report that has not been archived yet.
`SimilaritySessionTests.swift` verifies Dismiss and window close retain view
state; explicit Clear resets it. Resource tests include Automatic/CPU Only and
legacy resource preference compatibility.

## Resource changes on resume (2.2.16)

`SimilarityResumeTests.swift` also runs the real helper through pause, resource
edits and repeated resumes. It checks memory-based admission in helper progress,
lowered RAM budgets, atomic descriptor persistence, unchanged completed-file
reuse, backend pinning, unchanged app defaults and recovery in a new window.
Edits are rejected while running, for a stale session and for invalid Download
RAM. `SimilarityResourceTests.swift` covers restoring an editor from the scan's
own settings and older CPU checkpoints.

`test-similarity-resume.py <Resources>` lowers then increases RAM limits while
resuming a partially committed matrix. Original files are made
unavailable after analysis; all expected scores must still be retained.

`SimilarityResumeUITestApp.swift` uses two synthetic documents. Start a scan,
choose Pause & Adjust Resources, edit limits, then verify Save leaves it paused
and Save & Resume continues with the new limits. The fixture's Continue Sample
Discovery command lets the second document finish. It has no cloud credentials.

## Memory-based admission (2.2.17)

`SimilarityResourceTests.swift` checks independent Analysis RAM and Download RAM
editing, calculated totals, hardware ceilings and legacy worker migration.
`SimilarityResumeTests.swift` verifies that old worker preferences no longer
constrain resumed helpers while the changed RAM limits appear in live progress.
`test-similarity-memory-images.py <Resources>` runs real JPEG, HEIC and AVIF
readers with memory scheduling enabled and a deliberately small legacy worker
value. All originals must use memory transport and leave no processing files.

FileTwin's `native_contract` tests check mixed text/image reader allowances,
all reservation peaks, a decoder retry requiring the entire analysis pool while
originals wait, and smaller ready files passing a larger waiting input. The
tests exercise legacy admission too. Run with:

```sh
cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core
cargo test --locked memory_scheduling --no-default-features
```

## CoreML RAM admission and queue reasons (2.2.18)

The CoreML native contract runs memory and legacy modes: small ready images
exceed two concurrent visual jobs in memory mode, CPU documents continue, and
legacy accelerator limits still hold. Slot waits must not be labelled as memory
waits when the queued files fit. Capacity checks cover a 52 GB analysis allowance,
a smaller allowance, and a lower OS resource ceiling.

`SimilarityTests.swift` reproduces the 83-file / 67-ready-file progress snapshot
and verifies that occupied accelerator slots do not produce a memory warning.
`test-similarity-acceleration.py` now requires more than two actual CoreML jobs
on an available CoreML backend, checks every reported RAM reservation and compares
CPU/CoreML scores. It uses synthetic images and has no cloud credentials.

## Predictive download admission (2.2.20)

Photos unknown-size admission in 2.2.31 additionally uses bounded attempts;
the generic unknown-size safety guard remains intact. Run
`PhotosSimilarityConcurrencyTests.swift` for the app-to-helper protocol and
`SimilarityRAMPauseTests.swift` for partial-buffer retention during RAM edits.
See [Apple Photos download performance](APPLE_PHOTOS_DOWNLOAD_PERFORMANCE.md).

`docs/SIMILARITY_PREDICTIVE_DOWNLOADS.md` describes the forecast and hard
Banker safety guard. Targeted commands:

```sh
python3 scripts/with-client-credentials.py cargo test --lib similarity::
cargo test --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core memory_input::
scripts/build-native-test.sh scripts/SimilarityTests.swift /private/tmp/SimilarityTests
/private/tmp/SimilarityTests "$PWD/dist/MyCloudDriver.app/Contents/Resources"
python3 scripts/test-similarity-memory-images.py dist/MyCloudDriver.app/Contents/Resources
```

The Rust fixtures cover the 12 GB / mixed video-image scenario, unsafe partial
buffer grants, unknown lengths, changing throughput, real slow HTTP streams,
connection growth before completion, provider cooldown and cancellation cleanup.
The Swift suite covers per-file progress parsing and a synthetic Photos FIFO.
The UI fixture's **Show Cloud Download Progress** includes mixed sizes, live
speeds, RAM waits and retries; **View Downloads** jumps to the list. Check normal
and minimum window sizes, light/dark appearance, collapse/expand and list scrolling.
UI fixtures do not download or delete personal/cloud files.

### Automatic transfer admission

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib download_connections:: -- --nocapture
python3 scripts/with-client-credentials.py cargo test --locked --lib upload::tests:: -- --nocapture
python3 scripts/with-client-credentials.py cargo test --locked --lib similarity::fetch:: -- --nocapture
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak disk_download_tests:: -- --nocapture
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak transfer_control:: -- --nocapture
```

The connection-controller tests use logical time to cover capped bandwidth,
scaling bandwidth, later network improvement, provider cooldowns, stalled
streams, RAM pressure, pause/resume, and draining retained permits. In a shared
4 MiB/s model with queued 16 MiB originals, compare time to the first completed
file, completed files in 240 seconds, and aggregate received bytes against the
previous scheduler. This is a simulation, not a live PikPak speed benchmark.
Uploads use the same controller with a separate byte counter. A local HTTP
fixture verifies that retried and multipart request bodies count toward network
throughput while logical progress remains monotonic. Completed upload journals
must contribute no network bytes. Both directions ignore old app worker settings.
The HTTP fixtures verify expansion from four to eight live downloads before
any original finishes, cancellation cleanup, a cumulative network counter that
survives completion/removal of progress rows, and metadata timeouts separate
from healthy body transfers. No running user scan or proxy setting is changed
by these tests.

Disk downloads use the same controller, with an automatic safety ceiling of 64.
Their HTTP fixture expands from four to eight connections before any file
finishes, verifies both ordinary and shared-link request headers, and checks
every resumed file byte for byte. Its batch counter excludes preexisting partial
bytes. Queue tests cover pause and retry fairness with adaptive admission as
well as the existing fixed upload allocation.

### Download speed and direct routing

```sh
python3 scripts/benchmark-download-speed.py
python3 scripts/with-client-credentials.py cargo test --release --locked --bin pikpak download_speed_tests::inherited_proxies_cannot_reroute_downloads
swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library macos/PreviewTransport.swift scripts/PreviewTransportTests.swift -o /private/tmp/PreviewTransportTests
/private/tmp/PreviewTransportTests
```

The manual benchmark uses generated bytes on loopback, validates every completed
file, and removes its temporary files. It never authenticates to PikPak. The
wrapper removes proxy variables only from the benchmark process. The routing
regression deliberately supplies a fake inherited proxy in an isolated child
and checks account, shared-link, upload and metadata clients against a local
server. Native preview checks cover inherited environment settings, an explicit
direct URLSession configuration and deliberate app overrides.

On the development Mac, the same before/after fixtures measured:

| Fixture | Before | After |
| --- | --- | --- |
| Controller time to reach 64 useful streams (logical time) | 76 s | 28 s |
| New TCP connections for 96 requests, 16 at a time | 86 | 16 |
| Request fixture with 30 ms connection setup | 0.274 s | 0.116 s |
| Median local disk throughput, three 256 MiB runs | 1,827 MiB/s | 2,850 MiB/s |

These are synthetic development measurements, not live PikPak/CDN speed claims.
Short disk runs are especially sensitive to filesystem caching and CPU load.
The download pool retains up to 32 idle connections per host for 30 seconds;
active transfers still follow the throughput controller and similarity RAM
admission. Disk downloads buffer at most 256 KiB per active file and flush at
progress updates, pause, network interruption and completion. This follows
[Tokio's guidance on batching filesystem operations](https://docs.rs/tokio/latest/tokio/fs/).
The existing range, changed-original, pause/cancel and network-loss fixtures
check that buffering preserves resumable bytes and does not finalize bad data.
The native direct configuration explicitly overrides the default system route
described by [Apple's URLSession proxy documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary).

For the separate prototype comparing 1/2/4/8 ranges inside a single original,
see [PikPak download channels](PIKPAK_DOWNLOAD_CHANNELS.md). Run it with
`python3 scripts/with-client-credentials.py cargo run --release --locked --example download_channels`.
It uses generated loopback traffic and tests both per-connection and shared
bandwidth limits; it does not alter the shipping transfer paths or app state.
That document also records the explicitly selected live-original comparison
using `examples/measure_download_channels.rs`: two runs at each channel count,
validated byte ranges and equal sample hashes, with direct connections.
Its private plan accepts `channels` and `sample_bytes` for bounded comparisons
above eight channels. The production downloader does not read these options.

The production range implementation (2.2.25, build 200) is covered by
`download_ranges::tests`, `download_network::tests`,
`download_transport::parts::tests`, and `similarity::fetch::range_tests`.
These use generated loopback originals and cover cross-process disk restart
with holes, changed and malformed ranges, pause/cancel cleanup, retained RAM
pieces, memory-wait socket release, shared cooldowns and crash-released locks.
`TransferControlTests.swift` covers native cleanup of the new staging siblings
when the legacy `.part` no longer exists.

Rolling concurrency (2.2.27) adds deterministic tests in
`download_connections::tests` and `download_trials::tests`: sliding five-second
measurements, irregular polling, old partials, bursts, changing bandwidth,
repeated plateaus, RAM pressure, idle queues, server backoff, bounded fair shares,
and coordinated file/channel trials. The coordinator tests include a separate
process, expired ownership and private-file/symlink handling. The paced range
fixture starts another real HTTP channel from live measurements, then verifies
all generated bytes after stopping and resuming. Similarity's live admission
and disk admission fixtures run in isolated children so unrelated parallel tests
cannot contaminate the helper-wide aggregate byte counter. RAM fault-injection
tests start with two channels explicitly; disk pause tests establish flowing
traffic before stalling a piece. This separates recovery checks from bandwidth
discovery without relying on unrelated fixture downloads.

Normal downloads (2.2.28) use an absolute 1 MB/s gain threshold for file and channel
admission. Generated controller tests cover exactly 1,000,000 bytes/s, gains
just below and above it, low and high baselines, slowdowns, and repeated useful
growth below 10%. Existing rolling-window, pause, cooldown and coordinator
tests exercise the absolute policy. Compatibility coverage checks the relative
policy used by other transfer scopes; the paced range restart fixture exercises
the absolute policy while checking every accepted byte.
The disk admission fixture supplies about 0.8 MB/s per stream so adding two
streams can exceed the new cutoff, with 32 MiB bodies kept alive through the
rolling measurements. Its existing partial prefixes and shared-link referers
are verified along with all completed bytes.

Validation for 2.2.28: 210 library tests and 84 CLI tests passed. The release
app passed strict deep signature verification, packaged-engine startup and
source-hash verification. Build details are recorded locally in
`/tmp/pikpak-absolute-gain-artifact.json`. The build was subsequently installed;
transfer state and checkpoint backups were verified. The app was left closed
with the scan paused after scan work started again during reopening.

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak
```

See [the implementation plan](ROLLING_DOWNLOAD_CONTROL_PLAN.md) for results.

## Files changing during similarity scans (2.2.26)

See [similarity inventory reconciliation](SIMILARITY_FILE_CHANGES.md).
`similarity::inventory::tests` covers fresh metadata, same-size edits,
additions/deletions, paginated PikPak listings, Trash, failed inventories,
cancellation, revision-safe cache writes and comparison-generation changes.

`scripts/SimilarityInventoryTests.swift` runs the actual helper with generated
native files. It changes files after analysis and comparison, checks that
unchanged originals are acquired once, resumes a sealed comparison and verifies
that an entirely deleted file set yields empty results. It also checks native
disconnection handling, inventory refresh ownership and decreasing UI totals.


## Retain similarity downloads on pause (2.2.21)

- `python3 scripts/with-client-credentials.py cargo test --lib similarity::`:
  healthy response pause/resume, validated range continuation after a dropped
  connection, Clear while paused, completed originals retained through resource
  edits, safe RAM shrink and existing memory/fetch/encoding regressions.
- `scripts/build-native-test.sh scripts/SimilarityResumeTests.swift /private/tmp/SimilarityResumeTests`
  then `/private/tmp/SimilarityResumeTests "$PWD/dist/MyCloudDriver.app/Contents/Resources"`:
  same helper PID across pause/resume, live resource edits, account isolation,
  close/Cancel retention, crash recovery and Clear of a paused helper.
- `python3 scripts/test-similarity-resume.py dist/MyCloudDriver.app/Contents/Resources`:
  comparison checkpoint and abrupt process recovery, parent disappearance.

Cloud continuation follows [RFC 9110 ranges](https://www.rfc-editor.org/rfc/rfc9110.html#section-14)
and [If-Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5).

- `scripts/build-native-test.sh scripts/SimilarityRAMPauseTests.swift /private/tmp/SimilarityRAMPauseTests`
  then `/private/tmp/SimilarityRAMPauseTests "$PWD/dist/MyCloudDriver.app/Contents/Resources"`:
  synthetic Photos partial stream pauses with a zero-size FIFO, retains bytes,
  changes resources and resumes the same provider exactly once.

- `python3 scripts/test-similarity-live-pause.py dist/MyCloudDriver.app/Contents/Resources`:
  cooperative comparison pause freezes committed scores, keeps the same helper
  and resumes to the full matrix.
# Similarity cache and scan layout (2.2.22)

- `python3 scripts/with-client-credentials.py cargo test --lib similarity::`
  covers revision-aware source reuse, zero original requests on repeated cloud
  scans, provider cache hits without exports, and download/pause regressions.
- `scripts/build-native-test.sh scripts/SimilarityUITestApp.swift /private/tmp/SimilarityCacheLayoutQA`
  builds a synthetic UI fixture. Fixture → Show Cloud Download Progress checks the
  compact scan summary and single scrolling page; View Downloads jumps within
  that page. Fixture → Minimum Window Size checks the 940 × 740 layout.
- In the same fixture, select a result file and open Move to Trash. Return confirms
  and Escape cancels. The fixture simulates the provider acknowledgement; it does
  not trash files or access a real cloud/Photos account.

## Similarity Trash shortcut (2.2.23)

Build `SimilarityUITestApp.swift` with `scripts/build-native-test.sh`. Select a
reference file, then press Command–Delete to open its Trash confirmation. Escape
cancels; Return confirms. Select a match on the right and repeat: the confirmation
must name that match. Click the already-selected reference on the left and verify
that the shortcut targets the reference again. A group selection must not open a
single-file Trash confirmation, and Command–Delete in the search field must edit
text instead of opening a file action. The fixture only simulates Trash responses.

## Live analysis RAM updates (2.2.24)

`cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core --test native_contract live_ram_edits`
keeps a synthetic decoder busy through RAM increases and decreases in CPU and
CoreML modes. Limits must update while paused; queued files must complete without
waiting for the first decoder; every original is processed once and released.
Terminal progress must retain the latest limit. The existing
`SimilarityRAMPauseTests.swift` also checks both new limits in the app's progress
model before Resume while a partial Photos stream remains in RAM.

## Overlapping media reads from RAM

```sh
cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core
python3 scripts/test-similarity-memory-video.py --resources dist/MyCloudDriver.app/Contents/Resources
```

The core regression leaves a full-file HTTP response unread while requesting
other ranges, verifies that both responses retain their exact bytes, and checks
that cancellation joins readers and releases the original. Additional cases
cover incomplete headers, the per-original reader limit and recovered capacity.

The native fixture puts a legal 16 MiB padding box before an MP4's trailing
index, forcing FFmpeg to seek while its previous HTTP response remains open.
The old serial RAM reader times out on this valid file. Short and long videos
exercise continuous and sparse sampling; padded and unpadded variants must
produce identical frame selections and matching vectors. All four analyses
must finish from RAM without processing files, and the repeat scan must reuse
all four completed results. Fixtures are synthetic and require no cloud login.

## Saved scan progress and cloud byte progress

```sh
cargo test --locked --lib similarity::
./scripts/build-native-test.sh scripts/SimilarityProgressTests.swift /tmp/MyCloudProgressTests
/tmp/MyCloudProgressTests
./scripts/build-native-test.sh scripts/SimilarityRAMPauseTests.swift /tmp/MyCloudRAMPauseTests
/tmp/MyCloudRAMPauseTests dist/MyCloudDriver.app/Contents/Resources
```

`SimilarityProgressTests` drives the production model with a local helper protocol
fixture. It verifies every summary card/queue snapshot on pause, late analysis
completion while paused, the stopped clock, same-helper resume, two helper
restarts, cumulative transfer totals and resuming a sealed comparison without
double counting. Unknown snapshot payloads must not hide the recovery descriptor.
Nine small completed files with 90% of the bytes still in a large tenth file must
show 10% cloud progress; local and comparison progress keep their own units.
Download-time checks use aggregate speed and unresolved bytes even when cumulative
retry traffic exceeds the inventory. They cover cached/partial bytes, pause,
restart, stale/zero/invalid speed, incomplete inventories, long durations and the
transition to analysis/comparison after downloads finish.
Formatting covers months/weeks/days/hours/mins, omits seconds and zero/one unit
values, and carries single larger units down instead of discarding their time.
The RAR/ZIP and cache suites continue to verify that completed records reuse
without original requests. Rust coverage also checks origin-counter migration,
replay stability, byte totals beyond the visible 128 download rows, and finishing
a 200,137-file, paginated/nested cloud metadata inventory before any download
consumer reads it. The fixture includes repeated IDs, a folder cycle and hidden
files; it verifies the disk queue delivers every included file and the full byte
total. Other regressions cover more than 100,000 provider inputs and checkpoint
imports, reviewing/grouping a 101,137-file saved matrix, reopening an inventory
larger than the old 256 MiB JSON ceiling, and migrating capped legacy sessions
without mixing old ordinal-based comparisons into the expanded inventory.

`SimilarityProgressUITestApp.swift` displays synthetic 10%, 100%, incomplete
inventory, paused and waiting-for-speed states with the shipping scan view and
download time estimate. Build/run UI fixtures in a temporary
`.noindex` directory and remove their launcher registrations after testing.

## Password-protected similarity sources

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib similarity::
cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-worker --lib documents::
./scripts/build-app.sh
python3 scripts/test-similarity-password-skip.py --resources dist/MyCloudDriver.app/Contents/Resources
```

The integration fixture uses encrypted ZIPs, RAR4/RAR5 archives and a local HTTP service. Its
driver links the release scanner library because the shipping CLI has no API-host
override. It checks first-entry encryption, encrypted members after a public
entry, ignored and malformed ranges, immediate password-outcome storage, zero
content requests for cached exclusions, rechecking changed/decrypted revisions,
and continued retries for damaged archives. Sparse ZIP64 fixtures place the
directory above 4 GiB with an unencrypted first entry, including a maximum-length
comment that puts the ZIP64 record outside the tail. Slow header responses and
dropped connections must not lead to full downloads. RAR tests cover encrypted
data and filenames, mixed public/protected entries, legacy and numbered volume
names, and a RAR renamed to ZIP. Sparse RAR4 and RAR5 fixtures put a protected
entry after a 5 GiB public member; each probe must read less than 8 KiB instead
of downloading that member. Plain RARs and invalid header CRCs must not produce
password exclusions. Fixture provenance is in
`scripts/fixtures/similarity-rar/README.md`; no RAR executable is required.
Normal DOCX analysis and source reuse must still work. Unit tests also cover
RAR header CRCs, bounded variable-length integers, 64-bit packed sizes, truncation,
old-checkpoint migration, backend
and account isolation, missing revisions, corrupt outcomes, strict ZIP record
boundaries and retention of provider retry delays. No cloud login is used.

`WorkspaceSessionTests.swift` also verifies that search from an open scan restores
its closed browser in the same workspace/account, keeps the scan window, routes
both PikPak search scopes, and sends native search to the correct drive.
`WorkspaceSearchUITestApp.swift` is an offline UI harness for the shipping
`FinderSearchCommands`: verify Home → PikPak enables ⌘F and ⌘⇧F immediately,
then close the browser while Find Similar Files remains open and verify search
reopens that browser. Root search shows a configuration error in this harness
because it deliberately bundles no cloud helper or account credentials.

### Download-to-analysis RAM handoff

`cargo test --locked --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core`
checks that analysing originals release their download reservations, the full
40 GB Download pool can refill beside a 24 GB Analysis pool, and their combined
reservations stay within 64 GB. Logical reservations use tiny synthetic buffers.
It also checks zero-copy ownership, reader lifetime, cancellation, decoder growth
with a full download queue, and a bounded RAM error instead of a retry deadlock.
`cargo test --locked --lib similarity::memory` checks host admission, return to
Download RAM, duplicate release protection and live budget changes. Real video,
image, Photos pause/resume and native scanner fixtures validate decoder results,
cache reuse and retained originals using the newly built app's Resources folder.

### Continuous download queue

`cargo test --bin pikpak live_downloads::tests::live_queue_streams` runs a
loopback-only API and content server in an isolated child process. It holds a
body and a folder's second page open, verifies the first page downloads before
discovery finishes, appends another destination during that wait, drops a body
mid-transfer and verifies its resumed contents byte for byte. A paused selection
for the same cloud ID stays isolated and can be cancelled without fetching it.
A permanent failure does not stop unrelated files.

`scripts/DownloadRetryTests.swift` also checks the initial/later private inbox
wire formats and permissions, automatic start, progress preservation, scoped
controls, original IDs on retry, durable per-root acknowledgements, an inbox
append racing helper exit, and explicit Pause All. Use synthetic fixtures only.


## Apple Photos Fast Previews (2.2.32)

`PhotosSimilarityPreviewTests.swift` exercises generated photo and video assets
through the native provider interface and real Rust engine. It checks bounded
JPEG dimensions, eight per-file iCloud fractions, stale-callback rejection,
legacy Originals restoration, mode persistence, original IDs/names/sizes,
visual groups without original hashes, disabled size-based cleanup, and cached
preview reuse. Its fake provider rejects every original-fetch method.

```sh
scripts/build-native-test.sh scripts/PhotosSimilarityPreviewTests.swift /tmp/PhotosSimilarityPreviewTests
/tmp/PhotosSimilarityPreviewTests "$PWD/dist/MyCloudDriver.app/Contents/Resources" "$PWD/dist/MyCloudDriver.app/Contents/Resources/pikpak"
```

`PhotosSimilarityConcurrencyTests.swift` additionally delivers a generated 4 MiB
buffer using the production Swift writer and Rust reader, guarding against the
former 5 ms FIFO polling throttle. Existing original capacity, pause/resume and
cancellation scenarios remain applicable. Rust tests cover separate original and
preview cache revisions and the absence of original digests in persisted preview
matrices. These tests do not access a personal Photos library or measure iCloud
network throughput.


## Interrupted folder expansion (2.2.33)

The Browser expansion tests reproduce All Levels being interrupted with an open
but unloaded descendant, then reopen its ancestor. They also restore an
incomplete workspace or Back-navigation snapshot, deliver nested parent replies
in sequence, and switch between shared links. The assertions check that missing
visible listings resume, cancelled generations cannot populate the replacement
request, loaded children appear without toggling again, and active requests stay
at four. Cached empty folders, hidden descendants and genuine failures are not
automatically refetched. Cancel keeps unloaded branches stopped with Retry.

Compile `BrowserFolderExpansionTests.swift` with both `FINDER_WORKSPACE_TESTS`
and `FOLDER_EXPANSION_TESTS` to include the scheduler and workspace-cache checks.
`BrowserTreeRecoveryUITestApp.swift`, built with the same flags, hosts the real
Browser on a generated `9/P/V` hierarchy. After restoring the interrupted tree,
`Recovered file.txt` must appear automatically without any disclosure click.
The fixture reads no account credentials and performs no cloud requests.

## Settings icon stability (2.2.36)

`FinderSymbolImageTests.swift` checks the four Settings icons and fourteen
context-menu icons at 1x and 2x, including fixed dimensions after native symbol
configuration and separate cached sizes for menus and Settings tabs.

Build `SettingsIconStabilityUITestApp.swift` with `FINDER_WORKSPACE_TESTS` and
`SETTINGS_ICON_TESTS`. Open Settings and switch through General, Resources,
Accounts and Drives. The fixture sends twenty generated progress updates per
second and writes navigation render counts and toolbar image metadata to
`MyCloudSettingsIcons-<run>.jsonl` in the system temporary directory; `<run>` is
the bundle's `SettingsIconRunName` (or `sample`). While a tab remains selected,
updates must not increase the navigation render count, including while the
Resources monitor refreshes. All four toolbar images must remain fixed-size
bitmap templates. Pane controls must still update normally.

The baseline rebuilt navigation once per generated update; the corrected
General pane recorded zero additional navigation renders across 420 updates.
The fixture uses isolated preferences and no cloud credentials or Photos access.
