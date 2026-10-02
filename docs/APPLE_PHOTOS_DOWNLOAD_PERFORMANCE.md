# Apple Photos download performance

Status: Fast Previews and FIFO delivery fixes in 2.2.32; unknown-size admission fixed in 2.2.31 (2026-09-15).
Export and exact-only preparation improvements remain follow-up work.

## Conclusion

The normal Photos similarity pipeline now overlaps unknown-size originals
without claiming the entire Download RAM pool for each file. Album exports and
exact-only preparation still have sequential loops. PikPak's HTTP range connections cannot be applied through
the current PhotoKit provider: Apple owns the cloud transport.

## Fast Previews and visible progress (2.2.32)

New Apple Photos similarity scans default to **Fast Previews**. Photos use a
preview image and videos use a poster thumbnail. The scan requests PhotoKit's
fast image representation at a 1024 × 1024 target, accepts a cached lower-quality
result, and produces an aspect-preserving JPEG with a maximum edge of 1024 pixels.
This uses `PHImageManager.requestImage`, with network access enabled and the
current edited appearance. Apple documents that this API also returns a video
thumbnail: [requestImage](https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:)).
PhotoKit can still need iCloud data; this is not a guarantee of instant or offline
previews. No unavailable preview silently falls back to an original download.

The JPEG travels through the existing RAM pipe with an 8 MiB representation
limit. It is analysed as an image regardless of the original asset extension.
Original asset IDs, names and available original-size metadata remain intact.
Visual groups can include photo/video appearances; they do not compare a video's
full motion or audio. Byte-identical checks and Keep Smallest are disabled in
preview mode: matching JPEGs do not prove identical originals, and Photos does
not publish trustworthy original sizes here. Individual files remain reviewable.

Choose **Originals** before starting a new scan for original-content analysis.
Mode is saved with the scan and cannot change while it is running, paused or
showing saved results. Old saved scans retain Originals mode. Preview revisions
are separate from original revisions in checkpoints and vector reuse; saved
comparison matrices omit preview digests so later grouping cannot mistake them
for original hashes. Summary exports state the preview comparison basis.

Every active Photos request now has its own preparation progress. Rows say
**Waiting for Photos**, **Fetching from iCloud** with the reported percentage,
or **Reading into RAM** once bytes arrive. The header counts **Photos requests**.
Network percentages are never converted to invented byte rates. Retry tokens
reject callbacks from previous attempts.

The second reported stall also exposed a local handoff bottleneck. Stack samples
showed PhotoKit's callback repeatedly sleeping after a full FIFO; the helper also
slept after empty reads. Matching pipe inodes confirmed connected reader/writer
pairs. A generated 4 MiB Darwin FIFO experiment took 3.029 s (1.32 MiB/s) with
5 ms sleeps, versus 0.012 s with readiness waits. These are local handoff numbers,
not an iCloud throughput measurement. Both production ends now wait for pipe
readiness, with short timeouts to retain cancellation and reply handling.

## Original-mode admission fix

The reported scan initially showed one downloading original and seven RAM
waiters with only 256 KiB reserved from a 12 GiB pool. All 3,908 Photos inventory
entries had unknown sizes. The wait came from each file's possible maximum,
not from the amount of RAM currently occupied. Increasing the pool can admit
some previously queued claims, but new unknown files would claim the larger
pool again.

Unknown Photos originals now start with one eighth of Download RAM as their
maximum capacity, aligned to memory pages. With 12 GiB, that is 1.5 GiB per
original; each initially reserves only a 256 KiB receive window. The existing
eight preparation workers can overlap while memory forecasts and the safety
check still govern every admission and receive window.

If a PhotoKit chunk would exceed that capacity, the provider closes/cancels its
attempt and returns a structured `memory_required` lower bound. The helper
discards that attempt's buffer, reservation and pipe before retrying with a
fresh pipe and a larger allowance: at least double, or the reported minimum,
up to the full current pool. A file exceeding the entire pool reports the
existing Download RAM issue. Known sizes remain exact and are checked at EOF.
Invalid capacity replies and incomplete originals do not trigger this retry.

This can repeat a prefix of a large original; PhotoKit decides whether the retry
uses its cache or iCloud. Fetched prefixes remain included in delivery counters.
The provider's lower bound is never stored as an exact inventory size.
Pause/resume retains each in-flight attempt and its RAM; cancellation and
failed attempts release their resources. Generic unknown-length RAM streams
retain their conservative whole-pool behavior.

The 1 MB/s absolute throughput gain applies to PikPak disk-transfer admission.
PhotoKit does not use that controller, so changing it to 400 KB/s would not
resolve this RAM wait. The 1 MiB/s initial memory forecast is also a rate
estimate, not a minimum download-speed requirement.

An already running helper keeps its old code, including across an in-process
pause/resume. Use the new app/helper after saving and closing the old run;
completed analysis is recoverable, while unfinished originals are fetched again.

## Findings in the current code

| Path | Current behavior | Consequence |
| --- | --- | --- |
| Export individual selections | `NativeDriveModel.export` creates a transfer per selected item. `NativeTransferAdmission` admits 2–8 jobs, based on CPU count. | Separate photos can already overlap; the allowance does not adapt to transfer throughput. |
| Export a Photos album | `NativeDriveModel.exportOne` scans the album, then awaits materialization and the destination copy for each original before starting the next. | A single album uses one original request at a time, regardless of the outer job allowance. |
| Normal Photos similarity scan | Eight preparation workers request preview JPEGs by default. Originals mode uses bounded initial capacities and larger fresh attempts when needed. | Preview mode avoids requesting original resources; both modes retain RAM admission and cancellation. |
| Exact-duplicates preparation | The `exactOnly` branch of `NativeDriveModel.configureSimilarity` awaits each original in a sequential loop. | This separate preparation path also needs bounded parallelism. |
| Photos export disk I/O | PhotoKit writes a private staging file, then `ICloudDriveProvider.copy` reads and writes it again to the destination. | Disk copying delays the next original in an album and adds I/O, particularly for large videos. |
| Progress | Native exports show speed as “Not reported.” Scan rates count bytes received from the Photos FIFO. | Scan rates measure delivery to the app, which can include Photos' local cache; they are not a measurement of Apple's network connection. |

The safety check remains necessary: admitting several originals that can each
consume the whole pool can leave every partial original waiting for the others
to release RAM. Bounded attempts provide a maximum each provider can enforce.

## Apple API boundary

Originals mode uses
[PHAssetResourceManager.requestData](https://developer.apple.com/documentation/photos/phassetresourcemanager/requestdata%28for%3Aoptions%3Adatareceivedhandler%3Acompletionhandler%3A%29)
with network access enabled. PhotoKit delivers data asynchronously and supports
cancellation, but this API does not expose a signed download URL, byte-range
selection, or transport connection counts. Its callbacks use an arbitrary
serial queue; callback blocking should be included in performance measurements.

[Resource progress](https://developer.apple.com/documentation/photos/phassetresourceprogresshandler)
reports the fraction downloaded from iCloud. Data callback byte counts can also
represent cached content. Measurements should distinguish cloud waiting,
delivery to the app, RAM waiting, destination copying, and analysis.

Apple now documents an optional
[resource dataSize](https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva)
for macOS 27. It can still be unavailable until download or processing completes.
The installed Mac runs macOS 26.6.1, and the current SDK's `PHAssetResource.h`
does not contain this API. It cannot solve unknown sizes on this machine today.

iCloud Drive is a separate provider. Its originals are materialized through
`FileManager.startDownloadingUbiquitousItem` and file coordination, also under
macOS transport control.

## Remaining optimizations

1. Schedule Photos album members as bounded, concurrent original transfers.
   Use an app-wide Photos request allowance across selections, albums, exports,
   and scans. Preserve album cancellation, completed-item checkpoints, fair
   admission after pause, and collision-free destination naming. Avoid nesting
   permit waits while all parent album jobs hold the available permits.
2. Extend bounded preparation to the separate exact-only loop. Use trustworthy
   exact sizes when available and measure large-original retry costs.
3. Trial a small number of
   concurrent Photos requests and adjust using sustained original-delivery
   throughput, completion times, RAM pressure, and provider errors. Do not reuse
   PikPak's 64-connection ceiling or its network-byte metric as an Apple default.
4. Reduce export staging I/O by writing to a private temporary file on the
   destination volume and publishing it after successful completion. Preserve
   file coordination, destination validation, incomplete-file cleanup, and
   existing-file protection.
5. Report aggregate delivery speed and active originals for exports and scans.
   Keep cloud progress and local copy/analysis progress distinguishable.

## Verification and limits

Rust capacity tests cover eight simultaneous receive windows with a 12 GiB
pool, partial-claim release, page alignment, overflow and invalid replies, and
resizing. The existing `unknown_sizes_and_cancellation_cannot_strand_ram`
regression still protects conservative generic streams.

`PhotosSimilarityConcurrencyTests.swift` exercises actual Swift provider replies
and the Rust scan helper with generated in-memory originals. It covers eight
simultaneous unknown files, retained pause/resume, 8/16/32 MiB retries, known-size
validation, byte-identical final contents, whole-pool failure, malformed replies,
healthy peers, unique attempt pipes and cancellation cleanup.

```sh
python3 scripts/with-client-credentials.py cargo test --locked
scripts/build-native-test.sh scripts/PhotosSimilarityConcurrencyTests.swift /tmp/PhotosSimilarityConcurrencyTests
/tmp/PhotosSimilarityConcurrencyTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"
scripts/build-native-test.sh scripts/SimilarityRAMPauseTests.swift /tmp/SimilarityRAMPauseTests
/tmp/SimilarityRAMPauseTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources"
```

No personal Photos originals were fetched for these tests, and no measured
iCloud speedup is claimed. Compare a selected workload while recording cached
versus cloud acquisition and the cost of large-original retries before tuning
the number of concurrent requests further.

### Preview regression suite

```sh
scripts/build-native-test.sh scripts/PhotosSimilarityPreviewTests.swift /tmp/PhotosSimilarityPreviewTests
/tmp/PhotosSimilarityPreviewTests "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources" "$PWD/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources/pikpak"
```

This uses generated photo/video assets through NativeDriveModel and the real Rust
helper. Original access methods fail the test if called. Checks include eight
independent iCloud fractions, stale retry callbacks, legacy mode restoration,
JPEG dimensions, original metadata, persisted visual grouping, exact-hash
exclusion, and a second scan reusing preview vectors without provider requests.
The concurrency suite also times the production Swift/Rust FIFO using a generated
4 MiB buffer, while retaining its pause/resume, retry and cancellation checks.
