# Testing MyCloudDriver

## Download setup and receiving independence

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib download_share::tests::
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak download_verification::admission::tests::
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak transfer_control::tests::
python3 scripts/with-client-credentials.py cargo test --locked --offline --bin pikpak download_preparation
```

Generated loopback fixtures hold an inventory response while cached links are
resolved in the same helper and an independent helper. Restored uncertain
intents must share one complete reconciliation without duplicate POSTs. A
separate fixture blocks cloud setup for twelve files and verifies that later
ready bodies receive through their original concurrency limit. Oversized
metadata preparation cannot reserve disk byte capacity; actual reads retain
their byte and task bounds. A later ready check must enter an idle read turn
while an older selected check awaits metadata; holding byte admission outside
that cohort would otherwise create a circular wait. Existing completion, pause, shutdown and adaptive
replacement regressions cover RAM draining and throughput preservation.

Deferred-setup fixtures hold a generated HDD verification reservation while
account and shared downloads are dispatched four times, requiring one metadata
lookup through completion. Another fixture frees receive-ahead capacity after
an initial deferral, verifies that the missing suffix reaches RAM while the
reader remains blocked, and checks that durable bytes remain untouched until
verification advances. Admission also tests that stale receiving eligibility
cannot repeatedly rearm metadata while retaining its FIFO ticket. Unit cases
cover source/mode/size/revision changes, fixed expiry, normal-exit invalidation,
legacy path expiry, entry limits and the global setup memory budget.
Dynamic account and share cases also reject Guest bodies before deferring final
verification, requiring later dispatches to retain the selected User route
without repeating Guest requests or source lookup.

## Disk Trash and finishing similarity scans

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-native-test.sh scripts/DiskTrashTests.swift /private/tmp/mycloud-disk-trash-tests
/private/tmp/mycloud-disk-trash-tests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-native-test.sh scripts/NativeDiskDeletionTests.swift /private/tmp/mycloud-disk-deletion-tests
/private/tmp/mycloud-disk-deletion-tests
# Optional: uses only a unique generated directory on an already-mounted share.
/private/tmp/mycloud-disk-deletion-tests --network-root /Volumes/Share
cargo test --manifest-path vendor/FileTwin/Cargo.toml -p filetwin-core --test native_contract
cargo test --lib similarity::
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-native-test.sh scripts/SimilarityFinishTests.swift /private/tmp/mycloud-similarity-finish-tests
/private/tmp/mycloud-similarity-finish-tests dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
```

Disk Trash tests cover persistent original locations, duplicate names, repeated
Undo/Redo, Put Back conflicts and missing parents, emptying a confirmation's
snapshot, history invalidation, symlink/replaced/read-only/disconnected disks,
and preservation of unrelated contents in an existing Trash folder. Only marked
`Trash/MyCloudDriver` entries are managed. Connected external and network drives
prepare this storage in the background; native internal/iCloud Trash behavior is
unchanged. Both mounted-volume checks use exclusively generated files. The HFS+ disk image
uses an explicit Trash root because macOS gives disk images unknown external
flags; the network fixture also verifies automatic share-root selection without
opening or creating Trash among existing share contents.

The Finish fixture uses the real installed-format helper and generated text.
It checks Pause/Resume retains its helper, Finish while paused, a saved partial
report despite an uncooperative inventory, deferred provider cleanup, opening a
report without scanning, Resume reusing completed files, correct comparison
counts and deleting the report/record/matrix while preserving originals. It also
checks finishing during blocked preparation and rejection of stale callbacks.
The native engine fixture holds an active decoder and several uninterruptible
readers: Finish completes the decoder, admits no new analysis, returns promptly,
and safely retains then cleans the blocked readers' private directories.

## Delete from PikPak after download

```sh
cargo test --locked --offline --bin pikpak download_cleanup
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-native-test.sh scripts/DownloadCleanupTests.swift /private/tmp/mycloud-download-cleanup-tests
/private/tmp/mycloud-download-cleanup-tests
```

The download setup checkbox is off by default and persists across app launches.
Changes are sent to the active queue. Each owned file moves to PikPak Trash only
after a durable completion receipt matches its current cloud revision and local
file identity. Verified existing downloads qualify too. Folders and public
shared-link originals are retained. A cloud cleanup error appears on the
successful transfer without failing or retrying the download.

Only that check moves a downloaded file to Trash, so an item found in PikPak's
Trash has already been delivered. PikPak refuses to issue a download link for
it (`file_in_recycle_bin`, error code 9). That answer, and only that one, is
reported as a skipped file rather than an interrupted download, and cleanup
does not run for it. A copy still in the output folder at its full size is
named on the skipped row; any other refusal is still a failure.

Loopback tests cover the queue option, successful publication, existing-file
verification, changed cloud/local files, unverified copies, failed downloads,
shared originals, Pause, Cancel, a rejected Trash request and a source already
in the recycle bin. Native fixtures
cover preference persistence, updates to the live inbox, cleanup messages and
completion/retry/cancellation recovery. No real account files are deleted.

## Download checkpoint disk pressure

```sh
cargo test --locked --offline --bin pikpak download_transport::completion_tests -- --nocapture
cargo test --locked --offline --bin pikpak download_transport -- --test-threads=2
cargo test --locked --offline --bin pikpak download_receipt -- --test-threads=2
cargo test --locked --offline --bin pikpak download_fs
cargo test --locked --offline --bin pikpak live_download
cargo test --locked --offline --lib download_ranges
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-native-test.sh \
  scripts/DownloadCheckpointTests.swift /private/tmp/mycloud-checkpoint-tests
/private/tmp/mycloud-checkpoint-tests
```

The stalled-range fixture holds a generated loopback response after 64 KiB
across multiple checkpoint intervals. It checks that the durable journal's inode
and modification time stay unchanged, then releases the response and verifies
the complete payload. Separate cases check that EOF changes are still recorded
without additional bytes, a failed journal commit can retry the same coverage,
and an unchanged checkpoint still rejects a replaced staging file.

The completion fixtures count bytes returned by the actual piece-verification
and receipt-checksum readers. Generated 64 MiB account and shared-link downloads
each read 64 MiB before publication, with no second receipt pass. Other cases
check a freshly verified complete checkpoint after restart, a missing in-memory
proof, changed metadata, same-size edits with restored mtime, replacement files,
and a different source or revision. Only generated temporary files and loopback
HTTP are used; no existing downloads or account data are inspected.
Receipt regressions also inject an edit with restored mtime after digest reuse,
and exercise copy fallback and interrupted-copy recovery with the reused proof.

Resume and range journal commits run on blocking workers and are awaited before
coverage is considered durable. Existing data sync, checksum verification and
destination identity checks remain in place. These fixtures test app behavior;
they do not simulate a physical power cut or certify drive hardware.

The continuous queue carries `destination_kind` per request, using the volume
flags already collected during destination validation. The helper binds the
policy to that validated root, and both sequential and range downloads look it
up for their staging file. External disks and network shares save every 20 seconds
or 512 MiB of unsaved data; internal/unknown disks retain one second. Final,
pause and error checkpoints still complete before returning. Legacy roots retain
the environment fallback. Mixed destinations, aliases, inherited bookmarks and
roots appended to a running queue are covered without additional volume probes
during inbox encoding. This fixes the continuous queue bypassing the older
single-destination environment setup and flushing external disks every second.

## Long download names and Activity Log

Build 242 verification-admission regressions use generated loopback originals:
`cargo test --release --bin pikpak download_verification::admission` holds a
reader while 96 checks queue ahead of the sole HTTP receiver, proves RAM keeps
receiving, and then checks that every read advances without retrying. The
`deferred_final_verification` fixture preserves complete range proof across a
deferred check and a fresh retry state, and repairs only an intentionally
damaged piece. `normal_shutdown_drains_received_ram` exercises the admission
scope while draining both serial and range buffers before checkpoint recovery.

The recovered worktree's five-second rate fixtures also cover irregular
sampling, counters near `UInt64.max`, and pause/resume without changing the
app's one-second display cadence (`scripts/DownloadRetryTests.swift`).

```sh
cargo test --locked --offline --bin pikpak download_names
cargo test --locked --offline --bin pikpak long_download_name
cargo test --locked --offline --bin pikpak long_filename
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -parse-as-library macos/ActivityLog.swift scripts/ActivityLogTests.swift -o /private/tmp/mycloud-activity-log-tests
/private/tmp/mycloud-activity-log-tests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library macos/ActivityLog.swift macos/ActivityLogView.swift scripts/ActivityLogUITestApp.swift -o /private/tmp/mycloud-activity-log-ui
```

Generated loopback transfers cover URL-shaped and Unicode names, names whose
sidecars exceed the filesystem limit, account/shared downloads in all content
modes, receipt reuse, legacy partial resume, sparse resume in a new process and
interrupted copy publication. Activity Log checks cover fragmented helper lines,
exact level filters, multiline diagnostics, bounded history, error retention and
Clear. The UI fixture uses the shipping single-row footer: verify All levels,
Debug, Info, Warning and Error, collapse/expand, the error-count shortcut and
Clear. It uses synthetic messages and no account credentials.

The accordion header shares one row with transfer status and the level filter;
expanding it reveals entries underneath the header.

```sh
cargo test --locked --offline --lib download_share
cargo test --locked --offline --lib content_mode
cargo test --locked --offline --bin pikpak expired_original_downloads
cargo test --locked --offline --bin pikpak live_downloads
```

Unavailable original-share fixtures cover expired, deleted, rejected and
protected originals, new verified shares of the saved account copy, anonymous
content requests, durable share reuse and recovery messages at Info level.
An isolated child checks production log filtering. Disk recovery retains a
verified prefix, downloads only missing bytes and reuses the completion receipt.
Temporary outages and throttling must not create a share or consume account quota.

## Long download speed history

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -D FINDER_WORKSPACE_TESTS -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
  macos/SafeDisplayNumber.swift macos/DownloadSpeedHistory.swift \
  scripts/DownloadSpeedHistoryTests.swift -o /private/tmp/mycloud-speed-history-tests
/private/tmp/mycloud-speed-history-tests
```

Generated 11-hour and 48-hour counters exercise repeated RAM compaction and chart
reduction. They check that the first timestamp stays at the session's start, the
latest measured speed stays exact, and samples cover the whole timeline within
the memory limit. Time-weighted bytes and duration, averages, pauses, helper
counter resets, ETA and hover interpolation are also checked. The regression
previously moved the first plotted point more than six hours into an 11-hour
session, leaving a blank beginning despite the unchanged time axis.

`DownloadSpeedHistoryUITestApp.swift` renders the production chart with the same
generated 11-hour session. Compile it with `SafeDisplayNumber.swift` and
`DownloadSpeedHistory.swift`, without the test flag, and launch in an isolated
app bundle. The curve should span the full timeline. No live queue, disk or
account is used. Speed history remains RAM only and clears on app restart.

## Concurrent calculations, Guest downloads and cross-drive duplicates

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-native-test.sh scripts/RequestedFeaturesTests.swift /private/tmp/pikpak-requested-features-tests
/private/tmp/pikpak-requested-features-tests
cargo test --locked --offline --lib download_share
cargo test --locked --offline --lib download_connections
cargo test --locked --offline --lib download_network
cargo test --locked --offline --bin pikpak duplicate_cross_drive::tests
cargo test --locked --offline --bin pikpak duplicate_scan_tests
cargo test --locked --offline --bin pikpak download_checkpoint
cargo test --locked --offline --bin pikpak parts::
cargo test --locked --offline --bin pikpak guest_disk_tests
```

The native fixture launches four real helper processes concurrently without
credentials or network access. It verifies separate link/folder caches, unchanged
browser context, single-task cancellation and rejection of stale account results.
Checkpoint scheduling (`download_checkpoint`) is tested with simulated time: internal and
unknown destinations keep one second, external and network destinations save every 20 seconds or at
512 MiB unsaved, whichever comes first, and a save restarts both. The range tests (`parts::`)
cover trusting complete pieces only while the staging file's identity is exactly as saved, reading
back everything for a journal without an identity, an appended file, a copy or a corrupted piece,
the identity recorded after every checkpoint's sync, and older journals that load without one.
Real child-process restarts against the range fixture check that a resume fetches only the missing
range whether its journal carries an identity, carries none, or was touched afterwards; that a piece
damaged without a trace fails the final check, withdraws the trust, and is then fetched again on its
own (one 16 MiB range, not the file); and that the final check leaves a good journal alone.
Duplicate fixtures cover multiple disk and PikPak roots, local content hashes,
newer-folder recommendations, and changed or disconnected disk keepers. Repeated
scans fetch all current PikPak folder listings, ignore a stale account inventory,
and create no scan cache. Disk checks read matching-size candidates again, detect
edits and removals without saved hashes, and accept older scope files with unused
volume metadata. The removed `--refresh-cache` flag is rejected. Download
fixtures cover durable share reuse, uncertain creation and cancellation, anonymous
Guest requests, Guest-prefix/User-suffix recovery, and admission beyond 64 while
retaining bandwidth backoff and the shared descriptor budget.
The speed-history fixtures verify time-weighted averages, stalls, pauses, helper
counter resets, exclusion of resumed prefixes, remaining-bytes/average ETA and
completion dates across midnight, interpolation between chart samples, endpoint
selection, and bounded whole-session sampling with a fresh history after restart.
Queued-size fixtures also check approximate download progress against the cached
whole-selection total and its replacement as discovery completes.

## Live disk resources (build 237)

Settings → Resources shows physical-drive read/write rates in MiB/s and ATA/NVMe
SMART temperatures, plus disk rates for the app and its task helpers. Kernel
counters refresh every two seconds; sensor reads run independently every thirty
seconds while the pane is visible, with a five-second retry after transient sensor
failures. A failed request retains the last successful value for up to five minutes,
marked `cached`; its tooltip shows the original reading time and the sensor error.
No directories are listed, file contents read,
benchmark writes issued, SMART settings changed or self-tests started. Missing
or expired sensors remain unavailable. Empty card readers and virtual disks are
excluded; process accounting can differ from physical traffic because of caching.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun clang \
  -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c macos/DiskTemperature.c \
  -o /tmp/mycloud-disk-temperature.o
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
  macos/DiskResourceMonitor.swift scripts/DiskResourceMonitorTests.swift \
  /tmp/mycloud-disk-temperature.o -o /tmp/mycloud-disk-tests
/tmp/mycloud-disk-tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
  macos/TaskResourceMonitor.swift macos/DiskResourceMonitor.swift \
  macos/GPUResourceMonitor.swift macos/FinderAppearance.swift \
  scripts/TaskDiskResourceTests.swift /tmp/mycloud-disk-temperature.o \
  -o /tmp/mycloud-task-disk-tests
/tmp/mycloud-task-disk-tests
```

Fixtures cover real elapsed intervals, idle versus missing counters, resets,
sleep, disconnects and replacement disks with reused BSD names; SMART checksum
and attribute decoding, Kelvin conversion, transient failures, cached labels,
original timestamps, bounded expiry, recovery, retry intervals and removed devices; process reuse,
nested helper attribution and unavailable members. A blocked synthetic sensor
proves counters remain responsive, closing cancels polling and late results
cannot overwrite a newly opened pane. Optional `--sample` on `mycloud-disk-tests`
reads only the current Mac's registry counters and SMART sensor pages.

## HDD verification coordination (build 238)

Read-back verification on macOS resolves the open file's volume to its physical
IOKit storage device. Rotating disks share one verifier across APFS volumes and
helper processes; known SSDs bypass the queue. Unresolved local devices fall back
to a volume queue, and network shares retain their existing behavior. The queue
does not limit network requests or data writes. A waiting verification can delay
that file's publication; download-rate limits and integrity checks are unchanged.
The private advisory lock is released automatically when a helper exits.

An interrupted range piece that received all its bytes but did not observe EOF
now saves the SHA-256 context immediately before its last byte during the first
resume verification. Replaying that byte reuses the saved context rather than
reading the piece a second time. Changed or corrupt pieces still fail validation
and are repaired; final read-back and receipt checks remain in place.

```sh
python3 scripts/with-client-credentials.py cargo test --offline --locked --bin pikpak download_verification::
python3 scripts/with-client-credentials.py cargo test --offline --locked --bin pikpak download_transport::
python3 scripts/with-client-credentials.py cargo test --offline --locked --bin pikpak download_receipt::
python3 scripts/with-client-credentials.py cargo test --offline --locked --bin pikpak guest_disk_tests::
python3 scripts/with-client-credentials.py cargo test --offline --locked --bin pikpak \
  download_transport::integrity::tests::synthetic_eof_replay_benchmark -- --ignored --exact --nocapture
```

All fixtures generate their own data. Tests cover async and blocking queue users,
independent drives, queued Pause/Cancel, process termination, opposing two-drive
copy recovery without deadlocks, unchanged SSD
behavior, corruption repair and checksum-state boundaries. A loopback transfer
receives its entire body while its verifier waits, and another drive completes
independently. The EOF replay fixture reads 80 MiB rather than approximately
96 MiB for a 64 MiB download resumed from an unconfirmed 16 MiB piece, preserving
the full final integrity pass. Measure throughput on a quiet machine before and
after changing verification scheduling; synthetic timings do not guarantee the
same result on every physical drive.

## Incremental app builds and installation

```sh
./scripts/build-app.sh
python3 scripts/test-app-build.py
```

The build checks use the real Swift compiler with an isolated fixture. They cover
unchanged builds, edits that preserve timestamps, dependent-file type errors,
recovery after a failed build, compiler flags, damaged output and removed sources.
Installation checks copy the signed build to a temporary location without launching
it. They verify unchanged-install skipping, rejection of mismatched staging,
verified rollback archives and restoration after a registration failure.

For timing, compare `time ./scripts/build-app.sh --clean` with a second ordinary
build. `--clean` clears only the app's Swift compilation cache; Rust dependencies,
native torrent engines and model assets remain available.

## Bookmarks and resized transfer workspaces

```sh
./scripts/build-native-test.sh scripts/BookmarkTests.swift /tmp/mycloud-bookmark-tests
/tmp/mycloud-bookmark-tests
swiftc -parse-as-library macos/FinderTransferLayout.swift scripts/TransferLayoutTests.swift -o /tmp/mycloud-transfer-layout-tests
/tmp/mycloud-transfer-layout-tests
./scripts/build-native-test.sh scripts/TransferLayoutUITestApp.swift /tmp/mycloud-transfer-layout-ui
```

Bookmark checks use isolated preferences, synthetic cloud IDs and generated
local folders. They cover persistence, deduplication, account/drive isolation,
updates across windows, and opening folders or selecting files without fetching
their contents. Transfer geometry checks cover single, paired and three-column
boards, bounded controls and use of available height. Downloads additionally
check the 60/40 progress/setup split and four-metric row, including whole-cell
wrapping below the minimum usable width.

The transfer UI fixture uses production views and synthetic transfers. Its
**Fixture** menu switches between Uploads and Downloads and provides 600, 720,
1100 and 1400-point window presets. Check that setup/progress cards stack,
buttons wrap, every board remains reachable vertically, and resizing wider
restores columns.

## Automatic recovery

Run `zsh scripts/test-automatic-recovery.sh` after building the app resources.
It compiles and runs the combined offline regression suites for retry backoff,
helper exits, disk/provider interruptions, control-file write recovery, durable
Pause/Cancel intent, account isolation, torrent receipts, scans and previews.
All test payloads are generated. See [the recovery audit](AUTOMATIC_RECOVERY.md)
for operation coverage and conditions requiring user intervention.

The Rust disk-range regression
`newly_created_ranges_reverify_guest_checkpoint_before_sequential_user_suffix`
starts with a checksummed Guest prefix and no sparse journal. Its generated
User endpoint accepts the probe, rejects bounded parallel ranges, and serves
the remaining bytes sequentially. It verifies that internal staging conversion
refreshes checkpoint validation and that User downloads only the missing suffix.
`permanent_failure` in `src/download_policy.rs` is checked for each cause that
proves a file can never be fetched (account lookup says it is missing, the path holds a
different file, the content link is gone, a destination or retained staging file no longer
matches its receipt, with the refusal naming which of identity, size, contents or receipt
differs) and for every cause that must keep retrying
(throttling, outages, expired links, sessions, disks, permissions, unrecognised errors),
and the helper's `file_failed` event carries the reason only when one is proven. The
native suite's permanent-failure fixture checks that transient failures stay in Retry,
that three consecutive reports are needed before a file moves to Failed with its reason,
that another failure, a completion or a manual retry restarts the count, that a final
failure counts as finished while a retrying one does not, and that a row without source
details is explained rather than left waiting.
The native recovery suite also checks Retry section membership, retained bytes
and traffic, repeated retry events, restart admission, and folder/file controls
while a row waits. The loopback live-download fixture verifies the production
retry/dequeue event order and cumulative traffic across a resumed attempt.
Responsiveness fixtures also verify that repeated idle samples do not redraw
unrelated upload views, while changing rates and clearing stalled speeds remain
observable. The download speed (headline and per file) is the average of the
last five seconds of network bytes, refreshed about once a second: a burst lingers
for the whole window and a stall fades to zero as it empties, while Pause, Stop and
Cancel still zero it at once. `RollingRate` is also checked directly for the
steady, burst, interpolated-window-start, refresh-spacing and counter/clock-reset
cases.
Discovery presentation checks cover partial folder subtotals, cached estimates,
completion, interruptions and held or cancelled roots, so a partially discovered
queue cannot appear to be the full selection. While discovery runs, the size readout
and Remaining add what is already known about the undiscovered part: a file's size, or a
folder's cached size less what discovery has already added for it. A selection counts
the moment it is added, including while downloads are paused or held, so the total does
not wait for discovery and then neither falls nor counts anything twice as files are
found; a fully discovered selection contributes its exact size instead. A folder with no
cached size adds nothing and marks the figure as a lower bound (`≈ … +`). A cache that
discovery has already passed, another account's cache, or no known size at all fall back
to "Discovering total size…", a file retried on its own is never counted twice, and the
percentage never uses the estimate.

When a batch of downloads finishes completely (nothing running, queued, retrying or
failed from that batch, and every file downloaded) the status bar keeps a short report
of it: files, size, time, destination and average speed. Clicking the status bar opens
it, it stays until the next clean batch replaces it, and the dashboard restarts with the
next batch. A batch with any failed file produces no report. The native suite checks
this, and `DownloadReportText` is checked directly for its wording and bounded durations.

## Video preview recovery and folder merging

The standalone download fixture checks exact bytes across capped HTTP 206
responses, whole-file responses, missing metadata, changed validators,
overlapping or repeated ranges, cancellation and partial-file cleanup:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 5 -parse-as-library macos/MediaFileDownload.swift \
  scripts/MediaFileDownloadTests.swift -o /private/tmp/mycloud-media-download-tests
/private/tmp/mycloud-media-download-tests
```

Native preview and tree fixtures test both Up, Up, Down, Down and Down, Down,
Up, Up from the middle of seven generated rows with repeated titles. Delayed
media and bitmap loaders deliberately finish out of order despite cancellation.
The returned focus, source identity, player URL, generated payload and bitmap
must all match the original. Same-ID URL/revision changes, reconnected roots,
selection ranges and closing a preview also reject stale results.

```sh
./scripts/build-native-test.sh scripts/AVIPreviewTests.swift /tmp/MyCloudAVIPreviewTests
/tmp/MyCloudAVIPreviewTests
./scripts/build-native-test.sh scripts/NativeMediaPreviewTests.swift /tmp/MyCloudNativeMediaPreviewTests
/tmp/MyCloudNativeMediaPreviewTests
./scripts/build-native-test.sh scripts/NativeMediaPreviewWiringTests.swift /tmp/MyCloudNativeMediaPreviewWiringTests
/tmp/MyCloudNativeMediaPreviewWiringTests
./scripts/build-native-test.sh scripts/ExternalMediaBufferTests.swift /tmp/MyCloudExternalMediaBufferTests
/tmp/MyCloudExternalMediaBufferTests
scripts/build-native-test.sh scripts/PreviewResourceLoaderTests.swift /tmp/MyCloudPreviewResourceLoaderTests
/tmp/MyCloudPreviewResourceLoaderTests
./scripts/build-native-test.sh scripts/MediaPreviewInteractionTests.swift /tmp/MyCloudMediaPreviewInteractionTests
/tmp/MyCloudMediaPreviewInteractionTests
/tmp/MyCloudMediaPreviewInteractionTests --ui
```

The AVI suite requires the installed FFmpeg and generates Xvid/PCM and silent
MJPEG files. It decodes actual video frames through AVFoundation, exercises
native preview play/pause/seek, checks cloud-source fallback and cancellation,
and validates temporary-copy cleanup without modifying originals. A loopback
HTTP fixture checks media headers, incomplete downloads, HTTP errors and
download cancellation. It uses no cloud account or personal files.

The same suite generates an MP4 and reproduces a real AVFoundation parse
failure using deliberately damaged fixture cache bytes. It verifies one fresh
cache retry, then a complete download and compatible H.264/AAC copy when range
responses remain unparseable. It checks decoded frames, pause/autoplay intent,
seeking, cleanup, bounded retries and unchanged originals. Network,
authorization and protected-content failures must not trigger conversion,
while an inconsistent sample table reported as `-11880` or `-11869` must. It
also generates a Matroska file AVFoundation refuses to open, converts it with
FFmpeg's own demuxer, and checks that every supported container maps to an
explicit reader while playlists and archives map to none.
The standalone resource-loader suite checks extensionless MP4 URLs with valid,
generic, absent and incorrect MIME headers, plus the exact `-11829 / -12848`
failure from a damaged synthetic cache. All HTTP requests use a loopback server.

The media interaction suite generates H.264, VP9 and audio-only MP4s. VP9
reproduces an AVKit item that reports ready without rendering a video frame.
It checks first-frame detection, cloud-source fallback, local compatible-copy
recovery, paused playback, stale callbacks, bounded retries and cleanup. Focus
checks cover the header, video and controls, Space pause/resume with held-key
repeats suppressed, Space during player preparation, five-second Left/Right
seeks, Up/Down file navigation while a volume slider has focus, text input and
clicks outside the pane. The UI fixture uses the production pane, player and sliders
with three synthetic clips for pointer and keyboard verification.

The same suite checks PikPak merge eligibility for sibling folders, single
folders, mixed selections and ancestors/descendants. In the offline
`FinderWorkspaceUITestApp`, verify that **Merge Selected Folders…** remains in
folder context menus while disabled, enables after selecting Projects and
Notes, and opens the destination sheet. Verify the merge toolbar button and
File menu action in both List and Thumbnails.

## Browser file type filter

```sh
./scripts/build-native-test.sh scripts/BrowserFileFilterTests.swift /tmp/mycloud-file-filter-tests
/tmp/mycloud-file-filter-tests
/tmp/mycloud-file-filter-tests --ui
./scripts/build-native-test.sh scripts/BrowserEmptyFoldersTests.swift /tmp/mycloud-empty-folders-tests
/tmp/mycloud-empty-folders-tests
```

`BrowserEmptyFoldersTests.swift` covers **Hide Empty Folders**: the shared rule (nested empties,
a match several levels down keeping every folder above it, unopened, loading, failed or
paged folders staying, cycles, subsets), the setting (on by default, remembered), Local Disk
with a generated tree in List and Thumbnails (no folder is opened to decide, selection and
counts follow), and PikPak with folders in each load state. `BrowserFileFilterTests.swift`
turns the option off, since it checks the base filter where every folder stays.
Hide Empty Folders also applies to All Types. Confirm a known-empty folder hides
without selecting a category, toggling the option restores it, and completing a
listing or its final page updates visibility immediately. Loading, failed, unopened
and partially paged folders must remain; hiding never fetches their contents.

The offline suite covers categories, exact extensions, mixed case, provider MIME
metadata, extensionless Photos assets, expanded List rows, Thumbnails, selection
and keyboard ranges, cached listings, pagination, filename search and reset. It
asserts that folders stay visible under every filter, in place and at their tree
depth, while only files are matched, and that filtering does not fetch files or
scan unopened folders. The UI fixture uses production Browser views with
synthetic PikPak and Photos listings. Check the Filter menu, extension submenu,
the matching-file count, Clear Filter, and Load More when a page contains no
matches. Confirm that a filtered List still shows folders, indented, and that
expanding one reveals only its matching files.
The active category or extension must have a native menu checkmark. With a matching
file selected, change the filter and confirm selection, keyboard focus and the active
preview remain; Up/Down must still navigate the list. Mixed selections retain matching
items without restarting the focused preview. A hidden selection must clear its preview.

`BrowserScrollingUITestApp.swift`, compiled with `-D BROWSER_SCROLL_PROFILING -O`,
starts with 20,200 generated rows across expanded folders. The Benchmark menu also
offers 50,500 expanded rows. Command-Shift-B measures scrolling for 15 seconds and
records frame stalls, CPU time and row/outline work in the fixture's temporary report.
Use generated filenames only. List context menus share one native host: check first,
nested and scrolled rows, zoom, blank space, and the accessibility Show Context Menu
action. Open With must keep its application submenu while the list updates.

## RAM torrent uploads (2.2.46)

The native suite covers the queue-decode compatibility guard, per-file progress
parsing, shared-piece drain logic, `reselect`, streaming uploads, RAM reclaim
and sliding-window admission. It also checks download percentages/ETA and
automatic resume of paused legacy queues under the matching account. `queueCompatibility` must pass before any change to
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
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --rolling
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --storage
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --upload-outage
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --reconnect
python3 scripts/test-torrent-live-cleanup.py
python3 scripts/test-torrent-handshake.py
```

Storage-capacity regressions verify that switching and restarting admit more
than the former RAM limit, while RAM mode retains that limit. Synthetic low/free
space changes exercise unfinished-byte reservations, the overhead margin and
window expansion. The real `--storage` fixture selects all three generated files
and requires admission beyond its original 256 MiB RAM window after migration.
Storage tests also verify the default 100 GB free-space reserve, custom limits,
200-to-100 GB reclamation, narrowing a running selection without deleting partial
files, immediately increasing a limit, persistent settings, and retained pieces
surviving app restart without another cloud upload. Immediate cleanup is tested
with retention explicitly disabled.

Peer-cache tests verify torrent identity binding, 24-hour expiry, public numeric
endpoints, duplicate removal, bounded storage, private file permissions, and
corrupt/symlink fallback. The independent encrypted-peer fixture returns an
empty tracker response and restores its peer with `aria2.addPeers`, then checks
the full payload checksum. It also verifies that invalid endpoint batches and
oversized batches have no effect, and duplicate hints do not add connections.

`test-torrent-live-cleanup.py` also checks the bundled engine's verified resume
cache with private generated loopback data. Clean pause and process restart must
reuse verified progress; same-size edits with restored mtime, missing files,
legacy checkpoints, damaged trailers and altered piece bits must recheck. A
restart after live cleanup must reuse the cache without trusting released pieces
and must produce the expected SHA-256 for each remaining file.

The `--upload-outage` fixture keeps its synthetic PikPak sink offline across
RAM reuse, storage migration and app relaunch, then requires real loopback peers
to finish downloading all generated files to storage. Only after confirming
the pending payload is retained does it restore the sink; automatic retries
must upload every SHA-256-verified file and clean storage after confirmation.
Native tests also cover retry backoff, missing/wrong accounts, a lost commit
reply, full buffers, continued peer telemetry, manual Pause and Stop.
The storage migration case checks that disk usage can overlap confirmed cloud
bytes while overall progress counts those bytes once, then requires cleanup
after the final upload. Live token-to-normal login tests stop only the old
upload helper and verify unchanged torrent GID, destination, selection, peer
counts and engine pause/restart counts, including a switch during verification.

The native tests cover RAM reservations, RAM-only destinations, both pause/resume
stages, account and login-method binding, a lost cloud receipt followed by RAM
loss, restart of unfinished work and final memory release. The volume test
creates and detaches its own 256 MiB APFS RAM device; it checks case-sensitive
names, sparse boundary writes, volume reuse and denial of disk writes after
unmount. It also rejects a payload directory linked to disk. Never substitute
an existing disk device. Destination checks cover stale engine paths, traversal,
lookalike directory prefixes, symlinks and missing file lists.

The loopback test downloads generated torrent files directly into a real RAM
volume, pauses, recreates the app model, resumes partial pieces and compares
SHA-256 at the synthetic upload sink. It first attempts to resume a deliberately
disk-bound handle as a RAM relay and requires rejection before any payload is
written; after completion it checks the fixture queue for escaped payload.
Rust HTTP fixtures exercise the actual
PikPak/OSS upload path, content validation, lost responses, completed receipts
without source data, account mismatch and secret-free journals. No test sends
user files to PikPak or uses a public torrent.
The `--rolling` fixture transfers three generated 100 MiB files through a
256 MiB RAM volume, interrupts and automatically resumes from an old model's saved
progress, verifies every SHA-256, and requires multiple selections on one GID.
Its cleanup checks the fixture's volume UUID and owner marker before releasing
any RAM device, including after a failed test.

Storage migration tests copy sparse partial files and aria2 checkpoints, switch
during a blocked upload, reconcile a lost receipt, and verify the disk location
is persisted before RAM is released. They cover paused/stopped transfers,
relaunch, missing disks, failed copies, interrupted RAM release, unchanged cloud
destinations, shared-piece retention and automatic disk cleanup. `--storage`
uses a real 256 MiB RAM volume and loopback peers, moves a partial download to
disk, relaunches, checks SHA-256 at the upload sink and requires an empty staging
payload after completion. All files and cloud responses are synthetic.

Connection regressions recreate an unselected shared-piece stub and require
repeated censuses to preserve the running selection. A second fixture uploads
small files while keeping peers intact, then admits more files after a useful
amount of space is reclaimable, before the previous selection finishes. Pure
policy checks cover low remaining work, RAM pressure and the final window.
Storage migration also requires uploads and repeated censuses to retain the
running selection while the drive has room, with cleanup at completion. The
real storage fixture requires one selection throughout its download. Hash-check
regressions cover queued checks, an active check at zero bytes, and checking
starting between the lightweight poll and file census; none may restart the
window, remove a payload file or launch a new upload until verification ends.

Connection recovery fixtures inject repeated transport failures beyond the old
five-reply cutoff in both RAM and storage modes, then restore replies. They
require the same GID and selection, no pause/restart, refreshed peer counts,
uninterrupted cloud-upload telemetry, and working explicit Pause/Stop. Repeated
non-transport engine errors still pause through the normal error path.
The `--reconnect` scenario terminates and restarts its only loopback seeder
twice while a generated relay is incomplete. The client must keep its torrent
and RAM buffer active through both empty-swarm periods, resume downloading
without a user action, and deliver SHA-256 verified bytes to the synthetic
upload sink. No real transfer or network connection is interrupted by this test.

For isolated UI inspection, run the native test binary with `--ui-progress`.
Expand Peers, set the synthetic peer count to zero, pause/resume and restore the
peer. The disclosure must stay expanded. The fixture uses the production relay
card with generated progress and no account or download reads.

## Local torrent downloads (2.3.0)

```sh
python3 scripts/prepare-torrent-engine.py
python3 scripts/prepare-libtorrent-engine.py
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --dht
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --engine .build/libtorrent/runtime/bin/mycloud-torrent
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --storage --engine .build/libtorrent/runtime/bin/mycloud-torrent
python3 -m venv .build/libtorrent-test-python
.build/libtorrent-test-python/bin/pip install libtorrent==2.0.14
.build/libtorrent-test-python/bin/python scripts/test-libtorrent-engine.py
```

The native suite's re-dial test lets libtorrent write off an address after
three refused dials, then starts a seeder there with no tracker. libtorrent must
not dial it on its own; after one peer hint the transfer must complete
byte-identical. It sets `lt-min-reconnect-time=1` so libtorrent gives up within
seconds. The Swift suite's `peerRedialCadence` covers the app's five-minute
repeat. The `--dht` fixture's DHT query assertion expects aria2's bootstrap
pattern and fails with the libtorrent engine, before and after this change.

The native engine suite also covers an older cache that claims verified pieces
and partial blocks beyond EOF. Generated short files must stay out of the upload
queue, recover only the missing pieces, preserve intact shared neighbors, and
reuse the corrected checkpoint after restart. These tests never read live
download payloads or account credentials.
Explicit and legacy padding fixtures verify payload-only totals, virtual padding
without physical files, and cleanup of legacy padding stubs without withdrawing
real pieces. Model tests preserve padding offsets and old receipts while removing
padding from selections and upload progress.

For the energy regression, retain a copy of the helper before rebuilding, then run:

```sh
.build/libtorrent-test-python/bin/python scripts/benchmark-torrent-status.py \
  --baseline /tmp/mycloud-torrent-before
```

This creates 8,192 small files in a private temporary folder and checks their
verified progress through two isolated helpers, with discovery disabled. It
compares the former 1/5-second status/file cadence with the new 10/30-second
cadence, reporting detailed-response latency and process CPU time converted
from Mach ticks. It verifies that summary and per-file totals agree. These are
polling CPU measurements, not whole-app power or battery-life measurements;
the 20-second trials exclude periodic checkpoint savings and Swift UI work.
The model suite also verifies that returning credentials bypass a recent file
census even when its interval is set to an hour, and drives missing status
replies explicitly so recovery checks do not depend on the poll interval.

Measured locally on 2026-10-02 with the default 8,192-file, 20-second trials:
helper CPU fell from 36.66% to 4.24% of one core (88.4% lower). Median detailed
status latency fell from 598.50 ms to 299.35 ms. The fixtures use completed local
files without network payload traffic; these figures do not predict battery life
or the exact cost of a live swarm.

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

The native helper suite additionally verifies µTP-only delivery against an
independent libtorrent client, full-seed cleanup, retained TCP connections during
shared-piece cleanup/selection changes, last-piece availability announcements,
partfile reclamation and later file admission, fingerprint-validated resume,
modified/corrupt-cache fallbacks, confined deletion, and aria2 verified-piece plus
partial-block import. Its Python wheel is an isolated test dependency only.

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

## PikPak session recovery

PikPak Sign-in defaults to browser device approval. Continue in Safari supports
Passwords/iCloud Keychain on the real provider website; Use Default Browser uses
that browser's password manager. Sign in Here retains the embedded fallback.
The app requests `user pan offline`, polls the RFC device-code grant, and saves
only the independent desktop refresh credential with the same device identity.
No browser cookies, passwords or Safari refresh credentials are imported.

`PikPakBrowserLoginTests.swift` injects network/browser/sleep functions to cover
pending approval, slow-down, transport and service recovery, declined/expired or
untrusted approval pages, cancellation and late callbacks. It stages a generated
credential, simulates rotation, and opens a fresh account store to verify restart
restoration. Additional-verification challenges, including guest-link challenges,
must preserve saved credentials and must not reopen account sign-in.

The native suite also delays login preparation to check Preview & Scan Mode changes
from another workspace, cancellation, stale callbacks, rejected-session recovery,
and window closure. It uses generated accounts and an injected website-data
clearer; these checks do not open the real login page.

```sh
cargo test --lib auth::
cargo test --lib account_profile_
cargo test --lib personal_access_token
cargo test --locked mutation_safety_tests
cargo test --locked --bin pikpak upload_recovery_tests
./scripts/build-native-test.sh scripts/PikPakSessionRecoveryTests.swift /tmp/pikpak-session-tests
/tmp/pikpak-session-tests
./scripts/build-native-test.sh scripts/PikPakBrowserLoginTests.swift /tmp/pikpak-browser-tests
/tmp/pikpak-browser-tests
```

Mutation and upload fixtures verify that failed authentication/captcha preparation
releases creation intents, while lost creation replies remain uncertain. They
also cover a lost Trash reply or checkpoint update, already-trashed and missing
placeholders, content identity checks, completion before discard, legacy journals,
and removal of stale pending-upload tracking from the duplicate cache.

Loopback fixtures reproduce helpers rotating the same account unnecessarily,
including six independent processes. Checks cover reuse until expiry, a rejected
access token, late 401 responses after another helper refreshes, cache corruption,
credential/client/device isolation, and private cache permissions. Only explicit
refresh-credential rejection requests another sign-in; generic HTTP 400/401,
timeouts, and unrelated error numbers do not establish that the saved session is
invalid. Native tests verify a fresh account check before clearing credentials,
preservation during an outage, deduplication, and late replies after switching
accounts. No real account, transfer queue, downloaded content or file listing is
read. `PikPakAccountVerifierTests.swift` with its compiled fixture also tests the
real helper process error classification and cancellation.

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
python3 scripts/with-client-credentials.py cargo test --locked dynamic_
./scripts/build-native-test.sh scripts/GuestModeTests.swift /tmp/mycloud-guest-tests
/tmp/mycloud-guest-tests
./scripts/build-native-test.sh scripts/TransferDynamicModeTests.swift /tmp/mycloud-dynamic-transfer-tests
/tmp/mycloud-dynamic-transfer-tests
```

These use local HTTP fixtures and isolated preferences. They verify guest
identity checks, strict Guest behavior, per-file Dynamic fallback, disk/RAM
retries, resumed files, older queues, migration, preview invalidation and the
shared preview and scan mode preference. Native routing checks require Dynamic
for download helpers and live-inbox requests even when that preference is User
or Guest, including restored and resumed queues. Preview and scan helpers still
use their selected mode. The Dynamic fixtures also cover limited Guest prefixes,
remaining Guest ranges before account fallback, GCID/size verification, different
or missing CDN ETags, and retained parallel coverage. They use generated originals
only. `GuestModeUITestApp.swift` presents the production sidebar
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

The same command covers pruning of the saved vectors: entries unused for months
(sources, binary outcomes, then vectors nothing points at) are dropped while
recently used ones stay, even when only the older revision of an edited file ages
out; the 4 GiB size limit evicts the least recently used first and leaves no
source pointing at an evicted vector; reuse refreshes the last-used time at most
once a day; a cache from before pruning is upgraded without losing rows; and
opening prunes at most once a day. Apple Photos originals and previews, which are
two revisions of one file, still coexist.

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
| `ExternalDiskCatalogTests.swift` | Generated mounted-volume metadata: separate external/network groups, read-only filtering, duplicate names, disk identity, UUID-less SMB identity with credentials removed, server/share replacement, mount/unmount/rename refresh and observer cleanup. A blocked metadata loader proves that the UI remains responsive, refresh requests coalesce, stale results do not publish and closing rejects pending results. No real volumes are enumerated. Include `MountedVolumeIdentity.swift` when compiling this standalone test. |
| `DownloadRecoveryTests.swift` (speed monitor) | Pause All, or every unfinished file paused, holds the download speed monitor still: no samples, the active time and average are not diluted, the time remaining does not stretch, resuming records the pause as one flat gap, and a file paused while another runs does not pause it. |
| `DownloadRecoveryTests.swift` (idle sleep) | One macOS activity per downloading workspace; repeated heartbeats retain it. Pause permits sleep after RAM, verification and checkpoints finish; Resume and normal-Quit draining reacquire it. Completion, failure and close release it, and closing one owner does not release another's activity. A direct `pmset -g assertions` check verifies creation and release of `PreventUserIdleSystemSleep` without disabling display sleep. |
| `NativeMeasureProgressTests.swift` | Recalculate size progress on generated folders: one folder shows a running tally of files and size ("so far") with no invented percentage; several folders advance a bar one finished folder at a time (never backwards, ending full) and keep the tally; repeated folders and files in the selection still finish the bar. |
| `NativeDuplicateScanTests.swift` | Generated native duplicate scans: every run hashes matching-size files again, ignores hidden files and symlinks, detects same-size edits with restored modification time, additions and removals, and sends cross-drive scope requests without hash-cache metadata. No persistent scan cache or cloud credentials. |
| `ExternalDiskWorkspaceTests.swift` | Generated folders with injected volume metadata: external/network browsing and titles, return to the Mac folder, stale/wrong-disk rejection, download destination identity, independent windows, internal search/reveal routing, disk/share disconnect/reconnect recovery and Expand All Levels over several folders on an external disk and a network share. |
| `TransferRowPaginationTests.swift` | Fixed-size transfer row windows, page navigation and shrinking queues, empty/negative inputs, large queues and overflow-safe bounds. Only visible page rows are passed to the list; full queue processing is unchanged. |
| `SimilaritySessionTests.swift` | Separate four-drive scan scopes/results; Home → Scan drive discovers paused cloud/native scans with saved RAM/time settings, fresh ownership claims and account isolation; status dismissal/window close retain state; explicit Clear cancels and cleans up without late results. |
| `NativeListingTests.swift` | Large-folder listing. iCloud-only resource keys (about 1.2 s per 50,000 files, against 0.07 s without them) are requested only by the iCloud Drive browser or for a folder that is itself in iCloud. An ordinary folder lists rows identical to the full-key path (names, folders first, sizes, revisions, types, downloaded state), skips links and hidden files and still filters by search. File types are remembered per extension, equal to the direct lookup, safe from many threads and bounded. |
| `NativeThumbnailCacheTests.swift` | Shared grid/list/preview readers, visible priority, cancellation and late results, bounded decoded-image memory, revision/root keys, unavailable thumbnails and iCloud placeholders, current-folder pagination/cycle protection, and real Quick Look prefetch using a generated PNG. Folder warming stops after a bounded number of images (the cache holds only a few hundred) without reading further pages, and starts at the selected file and wraps. |
| `SimilarityFileActionTests.swift` | Original-provider Trash routing for all four drives; Keep Smallest groups/batches, ties, overlap, retained-file checks, partial acknowledgements, duplicate clicks, stale sessions and one-step Undo/Redo. Real Trash tests restore only synthetic local files. Uses synthetic accounts/assets only. |
| `SimilarityScopePickerTests.swift` | Direct folder selection, paging/deduplication, ancestor routes, loading and access errors, stale replies, close cancellation, and iCloud scan scope independent of Browser. |
| `NativeDriveTests.swift` | iCloud path boundaries, copying/rollback, cleanup revalidation, Undo/Redo, folder merge, Photos membership planning, search cancellation, concurrent native scans and Photos staging cleanup. A delayed provider withholds its second file until the first is analysed, proving discovery and analysis overlap. The Local Disk and iCloud size walk must match a full item scan (hidden items, symbolic links and overlapping selections excluded), including each folder's own total with throttled progress, and listed items must keep the identity a scan gives the same file. Pass the built app's Resources path to include real engine scans. |
| `NativeFolderSizeTests.swift` | Calculate on a folder shows the row spinner (also on unsized folders below it, never on files or unrelated folders), then sizes that folder and every subfolder, whether already expanded or expanded later; several selected folders are sized together; a refresh discards the sizes. Runs on generated folders and on newly created APFS, case-sensitive APFS, HFS+ and ExFAT disk images for the external-disk case, with folder names containing spaces and accents so a listing and the size walk must agree on each file system's name form; never touches a real disk. Needs full Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) when `xcode-select` points at the Command Line Tools. |
| `NativeDriveTreeTests.swift` | Inline disclosure, nested keyboard/range selection, remembered file focus on folder collapse/reopen, real temporary-file/folder Trash Undo/Redo, lazy loading and cache reuse, pagination/retry, sorting during I/O, bounded concurrency, refresh after rename/move/Undo, overlapping selections, Photos row identity and cancellation. Expand All fixtures cover deep/wide metadata trees, all descendant pages, cycles, cached branches, coalesced updates, Stop/collapse/reset/disconnect, stale replies, non-advancing pages and a generated local symlink; no file materialization. Replies that arrive together are published in one rebuild while a lone reply is shown at once. Expand All over several folders covers deduplicated and nested roots, ignored files, untouched unselected folders, the shared four-request bound, collapsing one expanding folder without stopping the others, and Stop cancelling all of them. |
| `FinderWorkspaceTests.swift` | Settings, CPU/resource attribution, GPU counter validity and live device readings, navigation, and account management. CoreML job counts are attributed once per task. |
| `WorkspaceSessionTests.swift` | Eight independent browsing workspaces; simultaneous different folders, selection/history/sidebar isolation, shared settings, independent drive titles, focused commands, resource aggregation, fresh storage on slot reuse, owner-specific scan recovery and idempotent teardown. Runs without presenting browser windows. |
| `WorkspaceTransferStorageTests.swift` | Generated per-window queues recovered in a separate process; UUID validation, legacy migration, paused-state preservation, inherited destination volume/bookmark checkpoints for nested downloads and cleanup-only imports, upload journals, exclusion of current-run workspaces and no repeated completed work. |
| `WorkspaceAccountSelectionTests.swift` | New-window account inheritance, explicit signed-out and sign-in-required selections, shared credential preservation and invalid namespace/account rejection. |
| `WindowTorrentRelayTests.swift` | Synthetic account routing across windows, login-method updates, weak ownership, fallback after closing a window, retention of the last relay account owner and account-specific listing refreshes. |
| `SimilarityLifecycleTests.swift` | Real helpers with isolated synthetic files: closing the browser keeps analysis running, scan windows retain account/storage ownership, result reveal reopens the same browser, Pause freezes active time, Quit saves it, and a fresh coordinator resumes without fetching completed originals. Also covers legacy descriptors and cumulative report time. Pass the app's `Contents/Resources` directory when running. |
| `WorkspaceAccountIsolationTests.swift` | Legacy per-window account/storage formats, refresh locks only for the same account, account switching and account-management regressions. These synthetic legacy models are not created by New Window. |
| `TransferPersistenceTests.swift` | Separate-process restore, once-per-account migration of old window queues, deduplicated imports, copied upload journals, import receipts that prevent completed-work resurrection, private permissions and preservation of corrupt/symlink state. |
| `TransferControlTests.swift` | Active/queued pause and cancellation, automatic retry, persisted cancellation of large-folder children (including a 100,000-record restore that must stay under a 250 ms main-thread budget), output ownership and cross-session cleanup, writer-close ordering, real local-copy interruption and preservation of original/completed files. |
| `NativeTransferFairnessTests.swift` | Paused/retrying transfers release worker slots, resume reacquires a slot, healthy transfers and other file actions proceed, rapid controls do not leak permits, and more paused filesystem workers than CPU cores leave Swift actors responsive. |
| `SimilarityResourceTests.swift` | Hardware-derived defaults, CPU/GPU distinction, custom integer bounds and serialization, memory admission, immutable scan snapshots and consistent memory units. Also compiles directly with `macos/SimilarityResources.swift`. |
| `DownloadRetryTests.swift` | Live queue admission across destinations and shared links, incremental totals, source IDs, durable acknowledgements, helper-exit races, pause/resume, retries and per-file network rates. |
| `DownloadRecoveryTests.swift` | Original destination volume checks, disconnect/access waits, reconnect, repeated disk-error backoff, durable root/child Pause including disconnected queued roots, immediate cancellation of visible and saved queues, overlapping-selection cleanup protection, cancellation totals, explicit re-add, late-event rejection and recovery across relaunch. Resume interrupts a slow cancelled-file cleanup between files, shows preparation while waiting for the current disk operation, starts without draining historical cleanup, and retains deferred cleanup across relaunch. Uses generated files and injected availability; never ejects an existing disk. |
| `DownloadDestinationReplacementTests.swift` | A download disk backed up and reformatted, on newly created ExFAT then APFS disk images mounted at the same path: the saved identity is reported as a replaced disk (not unplugged), re-validating without it adopts the new disk, an unplugged disk is still reported as unplugged, and only this app's own restored `.part`, `.part.resume.json` or `.part.ranges.json` for the queued items count as proof (a finished file or another name does not; the scan is bounded). `DownloadRecoveryTests.swift` adds the model flow: a replaced or empty disk never receives the download on its own and offers Use This Disk, Use This Disk or restored progress files continue it, the new identity is saved, and a third disk is refused again. Needs full Xcode when `xcode-select` points at the Command Line Tools. |
| `PreviewLayoutTests.swift` | Full pane width, height-only resizing, reachable bottom handle, one details-popover layout for every drive and placement (media keeps all but the grip), small windows and invalid saved heights. Also compiles directly with `macos/FinderPreviewPane.swift`. |
| `MediaPlaybackTests.swift` | Real AVFoundation playback, seeks/replay, stale callbacks after file switches, persistent volume/mute/speed, buffer gaps/overlaps and duration bounds, invalid preferences and observer teardown. Compile with `macos/MediaPlayback.swift`. |
| `NativeMediaPreviewTests.swift` | Native original preparation progress, cancellation/late completion, reuse across layout changes, retryable errors and safe staging cleanup. iCloud and Photos buffering panels persist from preparation to local availability, use actual provider byte counts for speed, keep a percentage-only speed unknown, decay to zero during a source stall, retain failure status and reject late progress after switching or closing. Covers video and audio. |
| `MediaContainerTests.swift` | A video's real container decides how it opens. First-byte recognition of MPEG transport streams (188 and 192-byte packets, three aligned sync bytes), QuickTime/MP4 atoms, AVI, Matroska, FLV, ASF, Ogg, MPEG program streams and RealMedia, and which extensions each container may carry. Plain-language failure reasons from FFmpeg output (missing movie index only for a file that starts like QuickTime, invalid data, unsupported codec, a full disk, never a path). Generated media through the real preview flow: a transport stream named `.MOV` plays natively from an internal disk (private `.ts` link, original untouched and still there after clear) and from an external disk (RAM buffer told the stream's type), Matroska named `.mp4` is converted by its real format, a genuine QuickTime movie is unchanged, a cut-off movie says its index is missing, and garbage says its data is not valid. A damaged 4K transport stream (junk spliced into the packet grid, so Apple's reader finds no video) is repackaged without re-encoding in seconds with video and audio intact, and a repackaged copy that fails again is converted once. A player that never finishes opening is abandoned after a timeout. Only containers Apple's player does not read are repackaged first (an MP4/MOV fails on its codec, so it is converted straight away). IINA is offered only when installed (a stale registration for a deleted app is ignored; standard locations are searched), and the original is handed over untouched, nothing being opened when the file has gone. The model exposes the original file and whether a copy is being prepared, so the button can show while it waits. The argument builder is checked directly: video copied and HEVC tagged for repackaging, hardware-first and downscaled to 1920 for conversion, the demuxer always explicit. Needs FFmpeg. |
| `NativeMediaPreviewWiringTests.swift` | Hosts the real inline preview in a hidden window with generated files, with direct playback, injected external-disk/network-share buffering and synthetic iCloud/Photos providers. Only the internal local disk omits the buffering panel. After every selection change, arrow-key burst and mid-load identity change the pane must be bound to the selected file, never left on "Preparing preview…" with the previous file prepared. Needs full Xcode (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) when `xcode-select` points at the Command Line Tools. |
| `ExternalMediaBufferTests.swift` | The RAM buffer for files on external disks and network shares. Pure store: automatic budget (1/16 of RAM, 64 MiB to 1 GiB), contiguous reads, rejected bad blocks, eviction behind the playhead first, never beyond budget or the playhead's block, concurrent use. File-backed AVAssetResourceLoader on generated MP4s with exact-frame decoding: a file that fits is held completely and released on invalidate; a file several times the budget plays from head, middle and tail within budget; head and tail priming with progress; a file that becomes unreadable fails the request instead of hanging. Preview model: external volumes and network shares play through the loader, internal ones directly, selecting another file releases the previous buffer, clear() frees it. Compatible external-video copies retain their preparation/completion panel after bypassing the RAM loader. Read throughput counts actual reads, including evicted bytes, ages out on a stalled read and resets on idle/resume. Buffer status reports retained bytes, source, RAM limit, completion and read failure; pending status updates cannot restore a cleared preview. The seek bar maps RAM byte ranges proportionally and reverts without a buffer. Volume rule: local non-internal disks and nonlocal network shares are buffered; the startup disk and volumes of unknown kind are not. Needs FFmpeg and, when `xcode-select` points at the Command Line Tools, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Selecting a video reads only its head and tail; a bounded window ahead of the playhead is read once playback starts (and not again when it is paused and resumed), and a released preview reads nothing. Downloads carry the validated destination kind per root in the continuous queue; legacy single-destination helpers use `MYCLOUDDRIVER_DOWNLOAD_DESTINATION`, and an internal legacy destination removes an inherited value. |
| `ExternalDiskTests.swift` | Creates its own 64 MB disk image: direct preview/export/upload sources, saved volume identity, ejection notifications, offline bookmark restoration without auto-mounting, read-only remount, incomplete-copy cleanup and replacement-disk rejection. Never uploads to a cloud account or ejects an existing user disk. Add `-D BROWSER_DROP_TESTS` to include uploader admission/resume checks. |
| `NativeDiskDeletionTests.swift` | Creates its own 64 MB mounted volume and generated files: Trash/Undo/Redo contents, expanded parent/child selection, connected-root protection, rollback after a failed batch, disconnected volume rejection and read-only remount. Optional `--network-root /Volumes/Share` checks on-disk Trash/Undo/Redo on an already-mounted writable network share using its own uniquely named disposable folder as the Trash root. Never lists existing disk contents or ejects an existing disk. Compile with `scripts/build-native-test.sh`. |
| `DiskTrashTests.swift` | Generated same-volume Trash entries: persistence, Put Back, Undo/Redo, conflict protection, Empty Trash snapshots, unrelated contents and native model state/history. Compile with `scripts/build-native-test.sh`. |
| `SimilarityFinishTests.swift` | Real helper with generated text and blocked inventory/preparation: Pause/Resume, Finish, saved report opening, Resume with reuse and score counts, record deletion and deferred cleanup. Pass the built app's `Contents/Resources`. |
| `DiskTrashSimilarityUITestApp.swift` | Isolated production workspace/commands with generated files: Trash, Put Back, Command-Z/Redo, Empty Trash confirmation, Finish report file actions, Resume and Delete Report. Build with `scripts/build-native-test.sh` into a fixture app bundle. |
| `FinderFileOpeningTests.swift` | File handoff, Open With, Quick Look loading, navigation, and cancellation. |
| `BrowserNativeMenuTests.swift` | Native Open With submenus for registered and unknown file types, application URL dispatch, the Other chooser, stable item identity across newly built menus and disabled actions. Compile with `scripts/build-native-test.sh`. |
| `BrowserDeletionNavigationTests.swift` | PikPak and native-provider previous/next selection after confirmed deletion: files, folders, expanded children, batches, boundaries and grid offsets. Failed deletion retains selection; a newer selection wins; clicking the canvas or changing filters clears the deleted position. Includes Trash/Undo outline regression. Compile with `scripts/build-native-test.sh`. |
| `FinderFileUndoTests.swift` | Undo/Redo history, partial completion, upload batches, account isolation, and restored files/folders appearing under their expanded parents. Add `-D FOLDER_EXPANSION_TESTS` to verify automatic branch reload requests. |
| `UndoTrashCacheTests.swift` | Trash updates after Undo/Redo, stale listing rejection, queued refresh after in-flight requests, account-switch cancellation and lazy loading. |
| `WorkspaceSwitchingTests.swift` | Tab switching, cached presentation, cancellation, and performance. |
| `SharedLinkSelectionTests.swift` | Selection across links, recursive roots, batch saving, and download routing. |
| `SharedLinkRetryTests.swift` | Batch retries, concurrency limits, saved access codes, selection preservation, cancellation, and selection regressions. |
| `TaskActivityTests.swift` | File-menu tasks, footer progress, results, and account-scoped updates. |
| `SimilarityTests.swift` | 5% minimum score, upstream raw counters, real saved-score row queries, tree identity, score precision, unmatched/skipped files, source isolation, cancellation and cleanup. Also covers automatic recovery of an interrupted scan (bounded attempts, budget reset on progress, user actions ending it) and the engine `note:` filter that keeps a status line from masking a real failure. Pass the built app's `Contents/Resources` path as its first argument. |
| `SimilarityTreeExpansionTests.swift` | Expand/collapse 250 groups, visible selection after collapse, search/regroup persistence, individual toggles, repeated commands, mode switches and whole-percent cutoff values. |
| `BrowserDragDropTests.swift` | Drag targets across full rows, nested/file parents, blank space, thumbnails, clipping, scrolling, spring loading and rejection; Finder providers with native NSURL, async ordering, Unicode paths, atomic failure and root deduplication; release handoff geometry, provider capture and destination capture. Compile with `-D BROWSER_DROP_TESTS`. |
| `BrowserFolderExpansionTests.swift` | Direct Expand All Levels action with no submenu, correct callbacks and fresh menu instances, cached fixed-size template icons at 1x/2x, and expansion plans covering cycles, duplicate IDs, repeated page tokens and partial-failure totals. Compile with `-D FOLDER_EXPANSION_TESTS`. |
| `CloudExtractionTests.swift` | Blocked extraction requests that explain themselves and keep the task, parallel inspection/extraction with independent progress and selection, per-archive password prompts kept in memory only, cancellation and API failures isolated to their task, bounded batch inspection, and queued password popups with wrong-password retry. Compile with `-D ARCHIVE_TASK_TESTS` and pass a built `CloudExtractionFixtureEngine` as its first argument. |
| `FileSearchTests.swift` | Search pagination, Unicode, ranking, limits, paths, navigation, cache replacement and redaction; offline local scope with duplicate link identities; transfer selection layouts and output collisions; Finder drop formats; and a live helper covering progressive root results, scope/cache isolation and cancel/reset races. Compile with `-D FILE_SEARCH_TESTS` and pass a built `FileSearchFixtureEngine` as its first argument to include the live-helper section. |
| `FolderSizeCacheTests.swift` | Exact and recursive deletion with ancestor updates and sibling preservation, overlapping multiselection, new folder/file insertion, moves across common ancestors, dirty-branch repair with clean-subtree reuse, size seeds limited to clean descendants, and complete-listing reconciliation that stays safe for unknown folders. With `-D FOLDER_SIZE_TESTS` it also checks that opening a folder for the first time during a scan keeps the scan while a changed listing still discards it, and that the saved-size store rereads a file replaced on disk. Compile with `-D FOLDER_SIZE_TESTS`; `cargo test --bin pikpak folder_measurement` covers the bounded concurrent walk. |
| `GuestModeTests.swift` | Guest Mode behaviour alongside the live download queue and retry suites. Its results appear under the download-queue PASS lines rather than its own. |
| `ICloudStorageTests.swift` | Quota parsing for personal, legacy, zero and enterprise responses plus invalid/ambiguous ones; a bounded read-only helper process covering missing commands, oversized output, timeout and cancellation; and refresh deduplication with truthful error state. Add `--live` to query the real macOS iCloud account. |
| `LocalVolumeStorageTests.swift` | Sidebar capacity for the disk behind a chosen local folder or external disk: used, fraction, name trimming, available space capped at the total, rejection of missing or negative sizes, a real volume read and a missing folder. The refresh model keeps numbers visible during a same-disk refresh, drops them on a different disk, discards a late result for a previous disk and after `clear()`, and ends an unreadable disk as unavailable. |
| `ImagePreviewTests.swift` | Thumbnails retained during API/full-image loading without a second empty frame, late thumbnail/original suppression and signed-URL refresh races, rapid selection changes without previous-file leakage, and bitmap/alpha/oversized/corrupt handling restricted to HTTPS sources. |
| `PikPakAccountStoreTests.swift` | Trusted-token migration into private directories without credentials in account metadata, independent device/token/lock files across sessions, duplicate sign-in replacing one account, symlink and untrusted legacy session rejection, and workspace isolation across 12 selections and 128 queue paths. |
| `PikPakAccountVerifierTests.swift` | Real helper success, expired credentials, offline failure, cancellation, process cleanup and retry. Pass a built `PikPakAccountVerifierFixture` as its first argument. |
| `PikPakTransferQuotaTests.swift` | Transfer-quota lifecycle across late replies, overlapping windows and cancellation; pass a built `PikPakAccountVerifierFixture` as its first argument to also cover the real helper's arguments, JSON delivery, failed refresh and process cleanup. |
| `PreviewTransportTests.swift` | PikPak CDN HTTP links upgraded to HTTPS with signed path/query bytes preserved, unrelated HTTP and malformed links rejected; inherited proxies disabled and an explicit override retained. |
| `PreviewProgressTests.swift` | Two million concurrent/burst cache events while the UI is occupied, latest-snapshot delivery, duplicate completed-cache reads, bounded update frequency, pending-event cancellation and release. No media or network access. |
| `PreviewResourceLoaderTests.swift` | Generated MP4s served over loopback: MIME variants, completed/damaged caches, actual frame decoding, a 30-second player buffer before/after duration discovery, and duplicate/stale UI metrics. Requires macOS 14 or newer and ffmpeg. |
| `PreviewResponseTests.swift` | Real preview JSON in User/Guest/Dynamic modes, HTTP/HTTPS source deduplication, legacy content-only replies, image/Quick Look/Open URL selection, and missing-link errors. Uses synthetic responses without network access. |
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
errors, durable byte checkpoints after disk loss, broken connections and read
timeouts, unavailable or replaced destination roots, and account/shared
downloads that outlive the metadata timeout. Guest URL expiry is refreshed once;
temporary Guest metadata outages retain their retry delay. A complete modern
checkpoint with a matching original hash and valid local checksum finishes
without another content request. Serial prefixes and sparse pieces bind their
saved coverage to local SHA-256 checksums; replacement, in-place edits and
uncommitted tails cannot certify bytes as downloaded. Legacy checkpoints
without checksums require validation.

`download_transport::retry_tests` counts bytes returned by the actual verification readers for
unchanged serial retries, helper restart, same-size edits with restored modification time,
replacement files and changed checkpoints. Generated capped HTTP responses advance the download
without prefix rereads, while publication still reads every byte once. The range suite also
checks incomplete-piece retries and one-byte EOF replay with the full final integrity pass intact.
The cache budget test checks memory/descriptor admission and release. Run the generated-file
retry comparison separately from the normal loopback throughput benchmark:

```sh
cargo test --release --locked --bin pikpak retry_read_benchmark -- --ignored --nocapture --test-threads=1
python3 scripts/benchmark-download-speed.py
```

The finalization fixtures force unavailable exclusive-rename/hard-link support,
as found on ExFAT volumes. They verify owned local-copy completion, prefix
checkpoint recovery, interruption before and after ownership/commit, safe
cancellation, timestamp-only changes during copying and recovery, independent
verification of staging/output bytes, stale empty-file identity checkpoints,
read-only recognition of complete matching copies, and preservation of
incomplete, edited or replaced destinations. Initial ExFAT allocation fixtures
separately exercise legacy first-copy identity recovery and reject mismatched
creation metadata, changed bytes and source provenance. Separate recovery
publication fixtures cover source-bound alternate files for uncertain legacy
copies, preserving the original destination, exclusive creation, interrupted
intent/ownership/copy/commit, restart, cancellation, and changed source or
staging rejection. Completion events report the actual recovered path with
unchanged logical names and network-byte accounting; native fixtures verify
the recovery notice and Show in Finder destination. Retained-progress
fixtures require an independently verified full staging checksum and check
that failure events do not count those bytes as new network traffic. Dynamic
download fixtures also cover HTTP 416 responses without a Content-Range
boundary: Guest refresh happens once, and verified Guest bytes are retained
while User ranges fetch the missing suffix.

Automatic conflict-recovery fixtures additionally verify deletion and retry of
unverified destinations, reset of damaged or missing staging plus serial/range
checkpoints, preservation of byte-verified staging after an inode change,
completed receipt skips, and cleanup preflight rejecting symlinked metadata
without deleting any payload. Dynamic malformed-range fixtures cover account
and shared-link downloads both from zero and with a verified prefix: Guest is
refreshed once, User finishes in the same run, and only the missing suffix is
downloaded after a resume.

Oversized-original fixtures cover account and shared-link Guest-to-User fallback,
verified prefix retention, early rejection of oversized Content-Length without
reading the body, and stable permanent reasons across changing byte counts. A
chunked overrun after reaching the expected size must invalidate the completion
checkpoint; a subsequent healthy response revalidates the saved bytes instead of
publishing a truncated original. The native retry suite verifies that three
matching permanent reports stop automatic retries and manual retry resets them.

The native retry suite also restores a single-file retry whose only Pause is a
saved request-scoped file control. It verifies that the pending row's pause
state matches admission, its saved size contributes before discovery, Resume
releases that control and submits it to the live inbox, and discovery replaces
the estimate without double counting or leaving the total undiscovered.
The retry-row fixture also starts a fresh helper after a failure and verifies
that its acknowledgement removes stale Retry history for that source/output,
preserves the same file's failure at another destination, keeps exact run totals,
and shows only the current error if the new attempt fails.

```sh
cargo test --locked --bin pikpak -- --test-threads=1
cargo test --locked --lib download_policy
```

`DownloadRecoveryTests.swift` also verifies persisted account/shared retry
ancestry, the helper's JSON object representation, cycle rejection, and
ancestor Pause/Resume isolation. Rust ownership fixtures verify that a resumed
retry needs the matching exclusive output lock and cannot claim an active,
paused, unrelated or foreign selection's partial.

The native download progress burst fixture uses an absent external-disk path
and 192 ordered updates to check one coherent published snapshot, retained
network/total byte accounting, completion ordering, and late-event rejection.
Progress paths use explicit directory/file URL hints so constructing those
paths does not probe a busy or disconnected filesystem on the UI thread.

`DownloadRecoveryTests.swift` uses temporary directories and injected disk
availability to check destination volume identity, reconnect and write-access
recovery, repeated-error backoff, paused folder children and disconnected queued
roots across relaunch, and cancellation while the helper is stopping. Cancel All must immediately clear
visible and saved queue entries, reject late progress, and remain cancelled
after relaunch or reconnect. Cancelling one item updates the remaining totals
and permits explicitly adding that selection again. It does not read existing
downloads or disconnect an existing disk. Cancelling an overlapping selection
must preserve the other selection's partial until it no longer needs that output.
The isolated ownership fixture also checks that an explicitly retried failed
child can reclaim its checkpoint while another child keeps the original folder
paused, without weakening restored-folder or live-body ownership.
Generated large restored queues also verify that ordinary discovery performs
no redundant persisted-queue or control writes, while newly inherited holds
remain durable. Pagination fixtures count source accesses to ensure each page
maps at most fifty rows, including reversed completed histories.
`AutomaticRecoveryTests.swift` checks that a failed control write survives an
unrelated preview-mode change and applies current Pause/Cancel actions to the
current helper when its control-file URL changes.

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
/tmp/mycloud-resume-tests dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
python3 scripts/test-similarity-resume.py dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
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
  --resources 'dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources'
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

Run `python3 scripts/test-similarity-file-handles.py dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources`
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
/tmp/native-drive-tests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"
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
`Resize sample.mp4` in the private folder opened by Fixture → Show Fixture Folder. Drag its bottom grip to
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
PikPak and Link show transfer speed, retained-byte progress and ranges inside
Buffering details below the player. The collapsed panel shows only its disclosure;
expanding it reveals status, speed, percentage, bytes and further information. The retained-byte buffer
is separate from the timeline's currently playable ranges. Confirm that iCloud,
Photos, external disks and network shares also use this disclosure; only the
internal Local Disk omits it. Provider speed stays unknown until bytes are reported.
All UI checks use synthetic media.

Loading cards must show percentage, received bytes and live speed before a player exists.
Force a compatible MP4 preview and throttle its full-file HTTP download; verify that the
loading card and buffering panel use those download metrics. A server stall must decay to
0 B/s, an absent Content-Length must use a known source size when available, and an entirely
unknown total must stay indeterminate while still showing bytes and speed. Conversion must
clear the download's percentage/rate, and completion, failure, cancellation or selection
changes must not retain stale metrics. `AVIPreviewTests.swift` exercises these with a local
HTTP server and generated media, alongside real parsing/recovery/playback checks.

Right-click a file and enter Open With. Leave the pointer on its trigger and
move between the parent and application list; the submenu must remain stable,
with application icons and Other… available. Other… must open the app chooser
and Cancel must leave the selection untouched. For a PikPak folder, choose
Expand All Levels directly, with no depth submenu. Test both list and
thumbnail views. Context menus explicitly use the standard button style: the
app's pointing-hand hover state must not rebuild a menu during native tracking.
PikPak and Link file/folder menus, plus native-drive single-file menus, use a native
snapshot until dismissal. Keep Open With open during loading/progress redraws, cross into
and out of its application list repeatedly, and check list and thumbnail layouts.
Enable **Simulate
Background Updates** in the design fixture, then keep the folder menu open while
the status counter advances. Check Browser and Links, list and thumbnails, hover
over Expand All Levels, Escape, and actual recursive expansion. Normal left-click
selection, disclosure and dragging must still work. Delete a selected file or expanded
folder in the middle of the list, then verify Up selects its former previous row and
Down its former next row in separate runs. Check the first/last row, multi-item deletion,
filtered rows, nested files and thumbnail layouts; arrow keys must not wrap at an edge.
The focused
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
codesign --verify --deep --strict "dist/AppBuild.noindex/MyCloudDriver.app"
```

To select an installed SDK explicitly, set `MYCLOUD_BUILD_SDK` to its absolute
`.sdk` directory (and `SDKROOT` to the same directory for the C objects). The
Swift cache records that SDK and its build version. This also permits using a
compatible installed SDK when the default Command Line Tools SDK lacks a
required SwiftUI macro plugin.

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

`python3 scripts/test-similarity-native.py --resources dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources`
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

`SimilarityResumeTests.swift` verifies close retains progress and a live helper,
Cancel opens a partial cancelled report and stops that helper, and Resume
reuses completed originals, completed results survive reopening in a new model,
and Clear removes both checkpoint and result matrix while keeping originals,
including a final helper report that has not been archived yet.
`SimilaritySessionTests.swift` verifies Dismiss and window close retain view
state; explicit Clear resets it, and Cancel during preparation opens a saved
zero-file report. `SimilarityProgressTests.swift` checks independent processing
and download progress, files/s and pairs/s, time-weighted averages, waits,
pause exclusion, restored-counter baselines, stage ETA and bounded history.
`SimilarityProgressUITestApp.swift` includes live synthetic processing and
comparison speed charts. Resource tests include Automatic/CPU Only and
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
/private/tmp/SimilarityTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"
python3 scripts/test-similarity-memory-images.py dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
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
scripts/build-native-test.sh scripts/PreviewTransportTests.swift /private/tmp/PreviewTransportTests
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
  then `/private/tmp/SimilarityResumeTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"`:
  same helper PID across pause/resume, live resource edits, account isolation,
  close retention, cancelled partial reports, resume without refetching completed
  originals, crash recovery and Clear of a paused helper.
- `python3 scripts/test-similarity-resume.py dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources`:
  comparison checkpoint and abrupt process recovery, parent disappearance.

Cloud continuation follows [RFC 9110 ranges](https://www.rfc-editor.org/rfc/rfc9110.html#section-14)
and [If-Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5).

- `scripts/build-native-test.sh scripts/SimilarityRAMPauseTests.swift /private/tmp/SimilarityRAMPauseTests`
  then `/private/tmp/SimilarityRAMPauseTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"`:
  synthetic Photos partial stream pauses with a zero-size FIFO, retains bytes,
  changes resources and resumes the same provider exactly once.

- `python3 scripts/test-similarity-live-pause.py dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources`:
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
python3 scripts/test-similarity-memory-video.py --resources dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
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
/tmp/MyCloudRAMPauseTests dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
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
python3 scripts/test-similarity-password-skip.py --resources dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources
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
/tmp/PhotosSimilarityPreviewTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources" "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources/pikpak"
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
Those flags also run the folder-selection checks: ⌘A selects the folders in the
current folder and no files, a refresh of that folder keeps the open outline,
its cached branches and the selection, while opening another folder resets them.
Expand All Levels over a selection runs as a single plan with deduplicated and
nested roots. Up/Down step one file at a time through the outline, including
rows inside expanded folders, and keep working after a step clears the previous
preview or lands on a folder that has none. In the app, verify ⌘A in List and Thumbnails, that a rename or
search field still selects its own text with ⌘A, and that right-clicking one of
several selected folders offers **Expand All Levels in N Folders**. With the
preview pane open, click the video surface or its transport controls and check
that Up/Down still walk the files while the seek slider, once focused, keeps
its own arrows.
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


### App audit regressions and Bookmarks

Run `scripts/build-native-test.sh scripts/NativeAuditRegressionTests.swift /tmp/native-audit-tests`
and `scripts/build-native-test.sh scripts/RootAuditRegressionTests.swift /tmp/root-audit-tests`,
then run the generated executables. `scripts/TorrentSafetyTests.swift` verifies
port-mapping response handling, lifecycle generations, TCP/UDP admission,
bounded helper execution, and descriptor-relative relay cleanup using generated
fixtures and loopback sockets. It does not contact a router.

`scripts/BookmarksUITestApp.swift` uses a unique preferences suite, its own
bookmark store, and a generated local folder. Open Bookmarks for PikPak and Local
from the Fixture menu. Verify list and thumbnail views, search, sorting, zoom,
multi-selection, and Return/double-click folder opening. A bookmarked folder
must open within Bookmarks; Back to Bookmarks returns to the virtual root.
Removing a bookmark keeps its target file. No live account or real Photos access
is required. The fixture deletes only its own generated folder on teardown.

The Rust engine also checks the file-system change itself with `cargo test --bin pikpak`
(macOS only): an unfinished sequential `.part` and a 64 MiB parallel-range download on a
newly created ExFAT disk image are copied (new device, inode and times) to an APFS image
and resumed, reusing the saved prefix and requesting only the missing ranges; a `.part`
restored without its checkpoint restarts instead of trusting its bytes.

`download_receipt_restore_tests.rs` (Rust, macOS only for the disk case) covers a finished
download restored from a backup: a copy with a new inode and times is recognized when its
bytes match the receipt, edited bytes are preserved and refused, a file whose receipt folder
was not restored is adopted only when its PikPak GCID equals the source's `gcid:` revision
(other hashes, time-based or unknown revisions, other sizes are refused and leave no
receipt), the incremental `GcidHasher` agrees with `gcid_file` across block sizes including
the 128 MiB doubling, and a finished download on a newly created ExFAT image survives backup
and restore onto an APFS image with and without its receipts.

The same file also covers skipping at the speed of a stat: a receipted copy that kept its size and
time is accepted with altered bytes and an untouched receipt (proving nothing was read or written),
a copy with another time, another size, no receipt, or another source is never vouched for by
metadata, and an in-place edit that restores the modification time is still caught through the
change time. `DownloadRecoveryTests.swift` covers the per-file verification progress the engine
reports and how it clears.

## Streaming RAM, disk phases and private diagnostics (builds 240–241)

`cargo test --release --bin pikpak` includes generated loopback receive-ahead
fixtures with a 4 MiB shared cap. A stalled writer still receives data; serial
and range consumers preserve byte order and independent written coverage;
cancellation releases queued leases and never checkpoints RAM-only bytes.
The same-disk test holds a read operation, proves reception progresses while
the staging file remains empty, then releases the reader and compares the
written generated original. Scheduler tests fill the network allocation with
verifiers and prove a new network body is still admitted. Hardware policy
fixtures cover 4/8/16 GiB devices, custom caps, pressure reduction and gradual
recovery. Traffic fixtures check byte budgets, small-queue deadlines, high-water
draining, starvation bounds, read/write exclusion and cancelled waiters.

`scripts/DownloadRecoveryTests.swift` also exercises independent received and
written UI counters, no duplicate accounting, helper counter resets, RAM usage
and persisted settings. The existing pause/cancel/recovery/integrity suites
remain required. Run disk-image fixtures on a Mac with an available DiskImages
service; they create their own ExFAT/APFS images and never use personal files.
The similarity range-pause fixture waits on the actual receive counter: fast
loopback pieces may finish before the 250 ms UI publication interval.

Build 241 adds a generated streaming checkpoint/resume regression: a fully
written 16 MiB piece retains its HTTP EOF proof before the entire download
finishes, so a restart reads only the partial next piece. The same fixture
checks the full final read-back and output bytes. Separate fixtures reject
EOF before written coverage, and hold the FIFO reader while 32 newer jobs
arrive, then require every waiter to advance. Native tests decode the new
queue-age/start/finish counters alongside older helper events.

Builds 242–243 add isolated scheduler regressions for 96 queued verifiers with
a single network worker. HTTP must enter the bounded RAM queue while the HDD
reader is held; every deferred read must later advance without a timed retry
or leaked RAM. Admission fixtures cover FIFO ordering, an oversized file,
the byte/task ceilings and dropped tickets. A separate regression holds cloud
metadata preparation for a deferred verifier, then requires a replacement body
to start. Sequential and ranged bodies are also allowed to finish into RAM
while their disk consumers remain blocked; replacement receivers must start
before those consumers are released. The pre-fix metadata case fails with the
only receiving slot occupied. Native heartbeat fixtures decode the anonymous
receiving/draining/disk-only counts and accept older helpers without them.

The deferred final-read fixture preserves completed piece proof, restarts with
fresh retry state without fetching intact pieces again, and detects generated
in-place damage before repairing only the damaged piece. These checks retain
mandatory end-to-end final verification and normal Quit draining.

For a generated transport benchmark with actual attempt/producer accounting,
run `download_speed_tests::download_speed_benchmark` with
`MYCLOUDDRIVER_BENCH_SCOPED=1`. Compare alternating runs with the variable
unset on the same binary; both paths verify every generated output byte. This
isolates the accounting cost from unrelated cloud/server speed variation.

An isolated scheduler regression replaces short transfers every 400 ms while
maintaining a continuous synthetic receive counter. Admission must grow beyond
the initial four transfers. This checks adaptation during frequent completions
without opening network connections or changing the production scheduler.

A separate isolated fixture fills a 4 MiB receive queue behind an in-flight
HDD read, then requests normal shutdown. Serial and ranged paths must drain
every received byte into a synced checkpoint, release a pending verifier,
admit no new body, preserve checksum trust on an interrupted final check, and
resume with a fresh retry state to the exact generated original. The native
Quit fixture waits for a synthetic helper's acknowledgement and verifies the
saved selection, automatic-resume intent and individual pauses on restoration.

The fragmented-range fixture sends generated 4 KiB HTTP fragments while its
disk consumer is stopped. At least half the 4 MiB receive budget must remain
usable for payload before the writer resumes; it then checks every generated
byte and EOF coverage. The previous 64 KiB reservation granularity stopped at
256 KiB of payload with all 4 MiB charged. Accounting now uses 4 KiB units,
independently of the unchanged 1 MiB serial and 64 KiB range batching limits.
Small queued buffers have compact backing storage. A partial-flush fixture
checks that a short serial batch does not retain its whole 1 MiB allocation,
while a full batch keeps the zero-copy path. Saved diagnostics include
`ram_reserved_bytes` alongside `ram_buffered_bytes` and `ram_limit_bytes`.

```sh
python3 scripts/with-client-credentials.py cargo test --release --locked --bin pikpak download_buffer::tests
```

Build 245 replaces the HDD's 512 MiB switching limit with five-second timed
turns. The timer starts with the first granted I/O operation, after the
previous turn's operations finish. Readiness distinguishes admitted readers
from checks still preparing metadata. Chunk gaps retain a runnable reader's
turn; an empty or idle side yields early. Large (1 GiB) or old (60 seconds)
read backlogs get an earlier turn once RAM falls below 64 MiB, after at least
250 ms of writing. A 75% RAM high-water mark drains to 50% before normal
alternation resumes. These are service and receiver-headroom controls, not a
limit on pending verification bytes or a promise of unlimited network input.

The traffic regressions simulate a write exceeding the next turn's deadline,
more than 512 MiB read in one turn, idle metadata preparation, inter-chunk
gaps, pressure hysteresis and age/byte priority. Actual asynchronous leases
verify read/write exclusion, FIFO serialized HDD writes, immediate completion
wake-ups and cancellation. A long-lived cancelled-ticket fixture bounds the
queue index. Existing generated serial/range tests still require reception
while the same HDD reader is held, complete byte integrity, graceful RAM
draining and checkpoint restoration. Native fixtures decode pending/writing
bytes, handover waits and turn counters while accepting older helper events.
Pending/writing counters divide budgeted RAM payload; a checkpoint can report
an active writer with zero payload bytes while syncing data or metadata.
Saved activity includes these counters and warns about verification waits of
at least 60 seconds. HTTP producers do not take read or write leases.

Build 246 samples adaptive file-worker occupancy after admitting ready
replacements. Sampling the transient vacancy before refill could repeatedly
reset the five-second throughput window when files completed near the 500 ms
sampling interval. The generated regression runs a continuous half-second
replacement workload with hundreds of queued items; it failed at four workers
before this correction and must now try additional capacity. Existing stable
gain thresholds, cooldowns, descriptor ceilings and live-transfer preservation
still apply. Native activity and saved numeric diagnostics include the file
worker target, occupied network workers, queued demand, and RAM acquisitions
that actually suspended. RAM wait counts and completed wait durations are
cumulative for a helper session; cancelled waiters release their diagnostic
count along with permits. A ready RAM acquisition is never counted as a wait.
These counters distinguish admission limits, full/pressure-limited RAM and
waiting for network delivery without logging names or URLs.

Build 247 retries a shared RAM reservation immediately when another producer
or consumer changes its atomic counter. A failed compare-and-exchange with
available capacity must not take the 50 ms pressure/capacity sleep. The
isolated contention regression runs 64 concurrent producers with substantial
headroom and requires zero suspended RAM acquisitions, complete permit release
and unchanged bounded admission. Real capacity and memory-pressure waits remain.

The terminal monitor reads one numeric, latest-only snapshot from
`~/Library/Logs/MyCloudDriver/Downloads/live-speed-v1.json`. The app coalesces
updates on its asynchronous diagnostics writer; this file stays within 512
bytes, uses mode 0600 and is separate from rotated history. The monitor performs
no process/socket enumeration and displays payload MB/s with a trailing
five-second average. Stale snapshots, sleep gaps and helper restarts reset its
window. `DownloadDiagnosticsTests.swift` covers coalescing and file permissions;
`python3 scripts/test-monitor-download-speed.py` covers rolling rates, resets
and bounded regular-file reads. Run `python3 scripts/monitor-download-speed.py`
on the Mac running the app, or run that command through SSH for remote viewing.

Build 248 also samples the range controller after replacing completed pieces.
Its deterministic admission regression completes a generated piece at every
500 ms sample, preserves real socket permits and requires additional channel
trials with continuous queued demand. It fails at one channel before the fix.
Existing loopback tests separately verify actual HTTP channel growth, byte
integrity, range validation, EOF, interruption and retained coverage.

Build 249 increases each normal HDD read/write turn to ten seconds. The clock
still starts only after the previous in-flight operations finish. Idle sides
yield early, and RAM pressure, old/large verification priority and graceful
shutdown still override normal timing. The phase regression explicitly retains
read I/O past the old five-second deadline and hands over at ten seconds; the
pressure regression keeps draining even after that deadline. Download speed
averages and connection-controller measurement windows remain five seconds.
The terminal reader tolerates publication delays up to that same five-second
window and labels partial/recovered averages as warming up. Delayed startup
snapshots must not repeatedly discard a valid rate history; incomplete windows
are excluded from full five-second low-speed counts in verification reports.

Build 250 freezes the registered pending-read pool at the start of each read
turn. New arrivals stay pending, and unfinished selected work returns to pending
at the ten-second boundary. Reading bytes describe this selected pool; separate
active/ready counters distinguish current I/O from prepared and deferred work.
The dashboard reads its target from the helper heartbeat rather than a duplicated
five-second label, and shows whole seconds for turn and wait times.
FIFO admission is reserved before a deferred verifier repeats metadata
preparation, still bounded to eight tasks/1 GiB (one oversized original may run
alone). Prepared readers enter the traffic gate before the single-reader
semaphore, so a handover to the next prepared reader does not empty the read turn.
New arrivals wait outside that semaphore until selected, preventing them from
holding the reader slot ahead of the current pool. Regression tests reproduce
both the former metadata head-of-line delay and premature handover, and cover
pool membership, retained progress and the ten-second cutoff. HTTP producers
continue into the shared bounded RAM queue independently of these disk turns.
Subsequent piece/final checks inherit their selected file's turn; a genuinely
new file remains pending. A short I/O handover gap does not end the selected
file's turn. The pool snapshot regression selects a generated 64 GiB queue,
keeps it visible between I/O calls, admits new data only to pending, and returns
exactly the unread remainder at the deadline. Preparation also rechecks its
byte reservation after a file grows, retaining the original FIFO ticket/age.

The saved-log tests need only Foundation and CryptoKit:

```sh
swiftc -swift-version 5 -parse-as-library macos/DownloadDiagnostics.swift scripts/DownloadDiagnosticsTests.swift -o /tmp/download-diagnostics-tests
/tmp/download-diagnostics-tests
```

They simulate nine days, restart IDs, rotation/byte/age caps, private file modes,
bounded queue overflow, partial crash records and one-second stalls. All
filenames and URLs in those fixtures are generated and must be absent from the
saved output. For live verification sample only process/network/physical disk
counters and these structured logs; do not open downloaded content, enumerate
download filenames or collect raw transfer/command-line output.

Build 251 extends the ten-second disk-turn checks to real sequential and ranged HTTP bodies: all queued RAM payload enters the writing cohort, arrivals during the turn stay pending, and both drains produce the expected generated bytes. An isolated 97-body test prevents finished RAM consumers from using the 64 verifier slots and starving replacement reception with free RAM. Live task contexts have a separate descriptor-derived ceiling; shared payload bytes still use the configured RAM allowance. Writer runs favor the same buffered output for up to 8 MiB before yielding to FIFO, without extending the ten-second turn or waiting more than two milliseconds for an unavailable continuation. Typed diagnostics distinguish selected writing bytes from active disk I/O and report descriptor admission capacity.

Build 255 groups HDD recovery saves by physical disk and volume. Generated
filesystem tests verify that 64 journals share exactly two full cache barriers,
that payload data is durable before journal publication, that each distinct
parent is synced once, and that neither a failed first barrier nor a failed
final barrier produces a successful acknowledgement. Changed payload identity,
replaced destination roots and journal symlinks are rejected. A concurrent
coordinator test holds the payload gate until 64 requests have queued, requires
one shared commit, and confirms that cancelling a caller cannot discard its
dispatched save. Requests retain at most 256 duplicate descriptors per volume;
each physical group admits at most 128 requests.

Traffic regressions require a new checkpoint to yield to payload I/O, a group
waiting one second to become eligible, and a full RAM queue to permit useful
read progress before urgent write handover. Schedule tests retain internal
one-second saves and bound deferred external saves to 512 MiB or sixty seconds.
The native recovery fixture decodes the five numeric group-commit counters.
Existing pause, graceful shutdown, restart, ranged EOF, destination replacement
and durable-prefix tests remain part of the full Rust binary suite. Live
verification uses only numeric diagnostics and generated fixtures; it must
compare checkpoint time, group size, physical I/O, RAM waits and five-second
payload rates over sustained operation, rather than infer success from a short
post-launch speed spike.

Build 256 separates verification dispatch from receiving slots. The isolated
`saturated_receivers_cannot_consume_verification_dispatch_capacity` regression
previously stopped at 64 of 71 checks while long-running receivers consumed the
historical extra allowance. It now requires every check to finish while the
single receiving slot remains occupied, and requires verified partials to wait
for that slot without retaining read admission or starting extra HTTP bodies.
Additional cases cover shrinking/growing the receiving target, cancellation
of a FIFO waiter, producer completion before RAM drain, and early handover when
a selected read cohort has no runnable reader. The native recovery fixture
decodes the numeric `receiving_admission_waiters` diagnostic. Rate comparisons
use the actual dashboard monitor and independent 64-bit physical-disk counters;
shorter intervals can differ because their boundaries do not align.

Build 257 retains an unfinished selected read cohort across preparation gaps,
including when no selected reader is ready for more than fifty milliseconds.
The regression failed with a Write phase at fifty milliseconds before this
change. The read clock starts when the preceding write has drained, so a cohort
that never becomes ready is still bounded to ten seconds. An asynchronous
case holds the next selected reader in preparation, requires a queued writer
to wait, then finishes the reader and requires early write progress. Separate
cases preserve pressure and control drains and select the most recent handover
across multiple physical disks independently of snapshot iteration order.

Native heartbeat fixtures decode read-handover sequence/cause, duration,
retained bytes and cumulative causes. Observed handovers have independent
numeric storage records rather than relying on a throughput-window boundary.
Generated saved-log tests reproduce the former silent rejection of rich
summaries above 96 fields, require a 160-counter window to survive, and retain
the new 192-field ceiling alongside record/rotation/retention caps. No download
filenames or content are required for these checks.


Build 258 replaces the read deadline with a strict pending-write threshold:
exactly 40% of the effective shared RAM limit retains the reader; the first
byte above it requests a safe write handover. Generated regressions cover a
900-second read below the threshold, immediate threshold handover, a reduced
limit under memory pressure, unfinished preparation, multi-disk selected-write
accounting, cohort replenishment without a write turn, and draining a small
tail once all verification is done. Frozen write cohorts still drain without
a deadline and arrivals stay pending for the next cohort. Native fixtures
check the threshold summary, handover cause/bytes/limit, backwards-compatible
decoding, integer seconds, pause and graceful Quit recovery. Live diagnostics
compare the dashboard's kernel rates with independent counters and reconstruct
read-only intervals from anonymous handover timestamps and durations.


Build 259 raises the unfinished-read handover to strictly above 80% of the
effective shared RAM limit. Boundary cases retain reads at exactly 80%, yield
on the next byte, and recompute against a reduced memory-pressure limit.
Existing frozen-write, multi-disk accounting, pause and graceful-drain checks
remain. The speed chart uses a fixed 0–100 MB/s display domain and 0/50/100
ticks; marks are clipped to the plot while recorded speeds, tooltip values,
overall averages and ETA calculations keep their measured values.


Build 260 removes repeated scoped-control scans ahead of unready verification
jobs and replaces receiving-admission broadcasts with FIFO targeted wakeups.
The generated 1,000-waiter regression checks that freeing one slot wakes only
one receiver, a cancelled head wakes its successor, increasing capacity fills
all slots, and cancelled waiters leave no permit leak. An isolated scheduler
regression covers direct, root and ancestor-path cancellation while other
queued work is paused.

Verification pipelines one sequential 1 MiB disk read with hashing the previous
buffer on a blocking worker. Generated integrity regressions cover offsets,
piece boundaries crossing both buffers, zero/one-byte reads, exact and partial
buffer endings, EOF replay, bad checksums and truncation. Existing full-pass
read counters, corruption/repair, Pause, normal Quit RAM drain and fresh-process
resume remain required. The explicitly ignored
`download_transport::integrity::tests::synthetic_read_hash_pipeline_benchmark`
compares eight interleaved old/new passes over a generated cached file and
asserts identical digests; it does not measure physical HDD throughput.
Stage diagnostics retain the existing bounded anonymous log format.

Build 261 reproduces the stalled-writer contention with 1,248 generated
waiters. Before the fix, every waiter receives a 50 ms timer wake behind an
active disk operation; afterward none do, and completing or cancelling the
head wakes its successor. A separate ineligible-queue case requires only one
idle coordinator timer. An isolated control fixture changes a private drain
document while I/O is held, requires parked writers to wake without overlapping
that I/O, and permits the finite later RAM cohort to drain for normal Quit.

Build 262 adds a deterministic handoff race: the checkpoint deadline expires
after a payload writer is notified but before it is polled. The displaced
writer must forward its wake to the checkpoint and both operations must
complete. Without the handoff, every eligible writer can remain asleep on an
idle disk despite the contention regression passing.

A generated loopback range fixture holds the disk reader, moves a partial
network chunk into the range coalescer, and checks that all received bytes
remain charged against shared RAM. It also checks shared allocation identity,
retention after receive-queue stop, generated byte integrity and charge release
only after output succeeds. Existing Pause, normal Quit, checkpoint barriers,
fresh-process resume, whole-file read-back and corruption repair remain required.
Native fixtures decode the added anonymous writer dispatch and eligibility
counters within the unchanged 192-field/16 KiB diagnostic record bounds.

### Build 276: receive-ahead permit lifetime

`download_transport::parts::prefetch_tests` holds a synthetic disk reader while
eight sequential suffix bodies finish. The ninth body must also finish receiving
before any saved-prefix check can proceed; all nine contexts retain their RAM
and complete with the generated original after the reader releases. A second
fixture rejects eight bounded-range bodies without sending data, then requires
a healthy ninth body to receive while those failed contexts still await checks.
The isolated fixtures verify returned receiving slots, retained context counts,
shared RAM accounting, and zero-byte failure diagnostics. The separate admission
unit test fills all 64 retained contexts, requires further admission to fail even
with free HTTP slots, and verifies full permit refund after cancellation/drop.
Existing generated Pause/Quit/restart and damaged-prefix tests remain required.

```sh
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak download_ -- --test-threads=4
python3 scripts/test-remote-download-monitor.py
```

Activity Log starts collapsed, including when restored activity contains errors.
New error entries retain their visible error badge without opening the panel;
the disclosure, error badge, filter choice and Open Activity Log controls expand
it explicitly. The generated Activity Log UI fixture starts collapsed with an
existing error so this startup behavior can be inspected without real downloads.

A generated sequential-channel fixture runs both ordinary and speculative bodies
with a one-channel network limit. Before consuming any buffered RAM, it requires
a replacement request to acquire that channel after HTTP EOF. The speculative
case must retain its unverified context until activation, and both consumers
then validate all generated bytes. This distinguishes HTTP channel ownership
from verifier/RAM-consumer ownership without increasing the connection limit.

The empty-prefetch Quit regression rejects a generated range body, retains its
unchanged prefix and journal, and holds the physical reader throughout Quit.
The attempt must exit as resumable before that reader is released. Existing
nonempty-prefix Pause/Quit tests ensure accepted RAM retains its read/drain
protection and reaches the checkpoint before shutdown.
