# PikPak download channels

## Being gentle with external disks and network shares

A running download saves its progress with a flush of the drive's cache (`F_FULLFSYNC` on macOS)
for the data, the journal and its directory. Once a second is fine for an internal SSD, but a
spinning external disk or a network share is kept busy, and warm, for as long as the download runs.

- **Calmer saves.** The app tells the download helper when the destination is an external disk or a
  network share (`MYCLOUDDRIVER_DOWNLOAD_DESTINATION`). Those destinations save progress every 20
  seconds, or sooner once 512 MiB is unsaved, instead of every second. Pause, Stop and errors still
  save at once. After a crash or an unplug only the network bytes since the last save are fetched
  again. Internal disks keep the one-second save.
- **Resuming without reading the whole file again.** Each save records the staging file's identity
  (device, inode, size, modified and changed times) right after the data is synced. A resume of a
  ranged download (64 MiB and larger) trusts the saved digest of every complete 16 MiB piece while
  that identity is exactly unchanged, and reads back only the partial pieces. If the journal has no
  identity (an older one), or the file changed in any way (edited, copied, replaced, remounted),
  every piece is read and verified as before. Sequential resumes verify their saved prefix when
  no valid in-process checksum context is available, including after a helper restart.
- **Retry without repeated verification reads.** Each queued transfer retains its incremental
  SHA-256 contexts across interruptions, pauses and Guest/User attempts. Reuse requires the exact
  checkpoint, staging path, device, inode, size and both timestamps to match an open descriptor.
  Changed data or checkpoints take the normal verification path. Contexts are memory-only, bounded
  to 16 MiB and 64 descriptors across the helper, with a 1 MiB per-transfer limit; unsuccessful
  admission simply uses ordinary verification. Completion releases the contexts. This changes no
  network limits, connection scheduling or retry delays. It removes repeated partial-piece and
  serial-prefix reads without removing the final disk read-back, including an interruption after
  the last byte but before EOF.
- **A safety net at the end.** Every finished ranged download is read once, end to end, and each
  piece is compared with its digest before the file is finalized. A piece that was damaged without
  leaving any trace outside the file therefore cannot be finalized, even if a resume trusted it.
  When that check fails the journal stops vouching for the file, so the next attempt reads every
  piece back.
- **One completion read.** That same verification pass computes the whole-file SHA-256 used by
  the completion receipt. The helper keeps an open descriptor and an in-memory proof bound to the
  source, device, inode, size and both timestamps, and reuses the digest only while all still match.
  Changed metadata falls back to a full checksum against the durable expected digest. A restarted
  helper verifies the retained bytes again before producing a new proof. Copy-based publication
  retains its separate source and destination checks. This removes one full-file reread from the
  normal range-download completion path without weakening its piece verification.
- **Damage costs the damaged pieces, not the file.** When a resume finds that some pieces no longer
  match their saved digests, it forgets only those pieces and fetches them again; every piece that
  still matches is kept. (Journals without digests still fall back to comparing a contiguous
  prefix with the server.)

Parallel range support for normal, shared-link and similarity downloads was introduced in
2.2.25 (build 200). The disk-pressure improvements above require a helper rebuilt from current
source. Small originals and incompatible servers keep the existing sequential path.

## Streaming download RAM and disk phases (build 240)

Disk downloads now receive into a bounded streaming RAM queue. A separate writer
drains chunks as the disk allows; it never waits for a complete file. Only bytes
accepted by the disk writer advance checkpoint coverage or checksum state. A
pause/error saves written bytes, discards uncommitted receive-ahead, and aborts
the HTTP producer. A crash recovers from the last synced checkpoint. Final
read-back verification is still required before publication and cloud cleanup.
Small network frames are combined into batches of up to 1 MiB. A partial batch
is released after 25 ms, so slow streams do not wait to fill the batch.

Settings → General provides a shared buffer ceiling for the download helper
and a RAM reserve for other work. Automatic uses detected physical memory minus
the reserve (8 GiB by default), so a 16 GiB Mac allows up to 8 GiB. On smaller
Macs the reserve is clamped to three quarters of physical memory. A custom
ceiling can lower the resulting budget. Nothing is allocated up front. Each
transfer can receive at most 2 GiB ahead, within the helper's shared budget.
System memory pressure reduces admission; existing queued bytes drain rather
than being discarded. Normal admission recovers gradually. Settings changes
apply to the next helper session. Separate helper sessions have separate
ceilings and react to the same system memory pressure.

Rotating disks also coordinate application read and write operations. Pending
verification work is measured in bytes. Read batches are bounded to 512 MiB or
five seconds, and small queues run after a short wait rather than waiting for a
full batch. During a read batch HTTP continues into RAM and writers wait for
the current read operation. At three quarters of the effective RAM limit the
disk switches to writes; it normally drains toward one quarter (at most 64 MiB) before another
read batch. A maximum write interval prevents verification starvation. Large
files resume hashing between batches, without rereading completed regions.
Pause/cancel lets checkpoint writers proceed after the in-flight read chunk.
Known SSDs bypass this disk-phase gate. Physical cache writeback and other apps
remain controlled by macOS. The existing verification process lock is retained
across helpers; phase coordination is local to one download helper.

From build 242, excess verification phases leave the running-attempt pool
entirely. A FIFO ticket retains only queue metadata and diagnostics, without
open download files, RAM payloads or network workers. Each rotating drive admits
at most eight verification phases and 1 GiB of estimated file bytes; an original
larger than that progresses alone. A multi-piece resume keeps its reservation
until its HTTP-to-RAM producer starts. Once received chunks have been written
and checkpointed, final read-back acquires separate admission. Deferring that
check preserves the durable journal and complete-piece proof; no network retry
or integrity failure is reported. Eligible checks have independent admission
even while receiving fills the adaptive network target, so older pending reads
continue to advance. The separate socket budget and adaptive throughput
controller retain their existing limits.
Queued tickets are reconstructed from saved transfers and durable checkpoints
after restart; ticket metadata itself holds no downloaded bytes. Normal Quit
still stops producers, drains received RAM, syncs checkpoints and waits for the
helper's acknowledgement. The RAM panel and private activity diagnostics now
also distinguish admitted checks from deferred jobs and record their byte
estimates and the cumulative admission-deferral count.

Build 243 also excludes a deferred verifier's metadata/output preparation from
network admission. An HTTP producer releases its network slot as soon as its
body finishes, while its disk consumer keeps ownership of queued RAM and
checkpoints. Replacement bodies can therefore enter RAM during verification,
read waits, writes and final saves. This applies to sequential and ranged
streams. Activity Log and private diagnostics distinguish receiving tasks,
completed bodies draining RAM, and preparation/verification tasks. Receiving
still applies bounded backpressure when the shared or per-transfer RAM budget
is exhausted or memory pressure requires a smaller budget. Pause, Quit, sleep,
network loss and server limits can also stop receiving.
RAM absorbs bursts and short disk stalls; sustained throughput is still bounded
by the connection, required verification work and disk performance.

Verification deferrals now retain prepared download metadata, the selected
Dynamic fallback route and resolved legacy queue paths for at most 60 seconds
from the original lookup. Cache hits do not renew that deadline. Entries are
transfer-owned and remain in RAM only, with a 32 KiB entry limit and a 16 MiB
helper-wide budget. Account/share, file ID, listed size/revision and content
mode bind download reuse. Expiry, changed source metadata, Pause, Cancel, real
failures and completion take the ordinary fresh-setup path. Rejected signed
URLs still follow the existing refresh/fallback policy.

Receiving eligibility is also recomputed when a deferred attempt starts. A
previously eligible prefix cannot keep reopening cloud setup every five
seconds after its route or journal stops qualifying for receive-ahead. The
original FIFO verification ticket survives that change. Eligible unfinished
downloads may still receive into bounded RAM while verification waits, and
their saved bytes must pass the existing checks before RAM becomes durable
coverage.

The **Download RAM buffer** panel directly beneath Download progress displays
current bytes, peak, effective/configured limits, memory pressure, pending read
bytes, remaining verification bytes and the current read/write phase. Speed
uses independently sampled received bytes, even while disk progress waits.

### Completed-piece proof and queue progress (build 241)

The streaming queue now delivers a validated EOF event for each piece, after
that piece's data events. The disk consumer retains this proof only after it
has accepted every byte of that piece. Checkpoints flush and sync those bytes
before saving coverage and proof. Previously, the RAM consumer learned EOF
flags only when the entire transfer ended; an interruption could therefore
make a later resume read already completed pieces again. A matching saved
staging identity can now reuse those pieces' digests normally. Missing EOF,
changed metadata, incomplete bytes and final read-back remain conservative.

The RAM panel also shows the oldest pending-read wait. Anonymous diagnostic
windows include `oldest_pending_read_ms`, `read_tasks_started` and
`read_tasks_finished` (process-lifetime totals). Queue bytes alone do not show
starvation: new final checks can raise the backlog while older reads finish.
Compare age and task progress with actual resume/final read bytes. The existing
FIFO verifier and 512 MiB / five-second read batches are retained. At a practical
220 MiB/s, 512 MiB needs about 2.3 seconds of pure reading; queue drain time is
longer because checksum work and disk writes also need service. Buffering
cannot exceed the disk's sustained capacity, and no artificial read-rate cap
or new network throttle is introduced.

Normal Quit also waits for a graceful download shutdown: the helper stops new
admission and HTTP reception, drains queued data (including a partial receive
batch), flushes/syncs the staging files and saves their journals before exiting.
AppKit uses asynchronous termination, so the app and its output handlers remain
alive until this finishes. All workspaces request the drain concurrently. The
selection and its original pause intent stay durable; the next launch recreates
unfinished verification from those checkpoints. Interrupting verification does
not withdraw saved identity/checksum trust merely because the user is quitting.
Large buffers can take time to drain. There is no shutdown timeout that kills a
writer and silently discards its RAM. Pause/Cancel keep their existing behavior.
An application crash, Force Quit or power loss cannot preserve volatile RAM;
recovery re-downloads bytes beyond the last synced checkpoint and still verifies
the file before completion or cloud cleanup.

## Saved download diagnostics (build 240)

Activity Log adds ten-second network summaries including one-second minimum and
maximum speed, resume/final read bytes, retry-cache hits, checkpoint latency,
RAM usage and verification queue counters. Slow operations and retries have
stable anonymous transfer identifiers. Structured records also include helper
and physical disk counters, allowing network stalls and disk phases to be
compared after a long run. Physical reads may include other apps; completion
and resume reads are expected when their diagnostic counters identify them.

Only typed events, numeric counters and HMAC identifiers are saved in
`~/Library/Logs/MyCloudDriver/Downloads`. Filenames, destination paths, signed
URLs, tokens, response bodies and ordinary helper error text are excluded.
The private identity key remains on that Mac. The writer is asynchronous with
a 256-record pending cap; overflow is reported and never blocks a transfer.
Logs rotate daily or at 16 MiB, retaining at most eight segments and eight days
(128 MiB total). Repeated launches reuse the current day's segment.

Use **Open Saved Logs** in Activity Log to read older JSONL segments with a
text editor, Console or a streaming JSON reader. **Copy Diagnostics** copies a
bounded recent tail (at most 512 KiB), without the identity key. A partial
record left by a crash is skipped; the following valid event remains readable.

## Implementation

`src/download_ranges.rs` supplies validated range scheduling to disk downloads
(`src/download_parts.rs`) and similarity originals (`src/similarity_fetch.rs`).
Files of at least 64 MiB can use parallel ranges, normally in 16 MiB pieces.
Larger pieces bound the journal for very large originals. The original signed
URL, existing account profile and direct HTTP client are retained.

Each file starts with one connection and probes higher counts. Normal and
shared-link downloads now retain a higher file or channel count when measured
aggregate body throughput improves by at least **1 MB/s (1,000,000 bytes/s)**.
The cutoff includes exactly 1 MB/s and is independent of the baseline speed:
100 to 101 MB/s qualifies, while 100 to 100.5 MB/s does not. This change is in
2.2.28 (build 203). Similarity and upload admission retain their existing 10%
threshold.

From 2.2.27, sampling uses
the latest five seconds, updated every 500 ms, with two seconds to settle after
a change. A complete fresh window must be stable before a trial is judged.
The former fixed 30-second trial delay is removed. Repeated unhelpful trials
require five, ten, then twenty seconds of fresh stable evidence; a sustained
rate change of more than 20% clears that plateau history. Eight is not a per-file ceiling. Small remaining
ranges, available RAM, server feedback and the other active files constrain
admission. New files enter the running queue; there is no batch barrier or
worker-count setting.

`src/download_network.rs` enforces 64 active original requests across the app's
helpers through private advisory locks. All accounts and windows receive the
same `MYCLOUDDRIVER_DOWNLOAD_CONNECTIONS` directory. CLI users without that app
environment share the allowance within their process. Idle HTTP keep-alive
connections are separate from active response bodies. Queued starts get local
semaphore priority, and active range transfers divide available capacity.

File-count and per-file channel controllers share one trial coordinator. A
private expiring lease prevents simultaneous deliberate trials across helpers;
a generation change invalidates old baselines. Trial decisions use aggregate
original-body bytes within each helper. Ownership expires after 15 seconds,
while an actively polled trial is abandoned after 12 seconds without a usable
result. Small metadata locks do not hold download sockets. Pauses, unavailable
RAM, draining connections and byte-counter resets cannot establish a baseline.
Uploads use the rolling controller with their own counters and admission pool.
See [implementation plan and validation](ROLLING_DOWNLOAD_CONTROL_PLAN.md).

HTTP 429/5xx responses preserve `Retry-After`, reduce new connection admission
and share a cooldown with other helpers using that serving origin. Reduced
capacity is remembered for at least 30 seconds after the cooldown; further
probes can then assess whether it has recovered. An expired URL or one broken
connection does not reduce unrelated servers' capacity. Every retry resolves
the original again through the existing transfer workflow.

This server-error recovery period is separate from the removed trial delay.

The investigation originally identified parallel byte ranges as the next
candidate after automatic admission of whole files was implemented.

Parallel byte ranges are supported by the following upstream evidence.
PikPak's [September 4, 2025 speed announcement](https://mypikpak.com/en-US/blog/download-speed-enhancements)
says its own app uses concurrent connections and explains that international
network paths can still limit total speed. That supports testing this approach;
it does not establish a particular speed or connection limit for this account.

[aria2's manual](https://aria2.github.io/manual/en/html/aria2c.html)
distinguishes parallel files (`--max-concurrent-downloads`) from connections
inside each file (`--split`, `--max-connection-per-server`). Automatic file admission addresses the former; the new range scheduler adds
the latter.

## Reproduce the experiment

```sh
python3 scripts/with-client-credentials.py cargo run --release --locked --example download_channels
```

`examples/download_channels.rs` uses the app's HTTP client with a dummy refresh
token, generated bytes and a loopback HTTP server. It never authenticates to
PikPak, opens user originals, enables a proxy or changes saved transfers. Each
run downloads a 32 MiB original with 1, 2, 4 or 8 connections into either RAM or
a temporary disk file. Every response's status, range, length and ETag must
match, and the assembled file's SHA-256 must match the generated original.
Temporary disk files are removed on exit.

The two fixtures distinguish a limit of 8 MiB/s on each connection from a shared
8 MiB/s limit across every connection. These intentionally controlled conditions
show when segmentation can help. They do not measure the user's ISP, HTTPS
setup, PikPak CDN, account quota, or the full similarity pipeline. This prototype
does not implement production pause, recovery or URL-refresh behavior.

Measured on the development Mac, September 14, 2026 (MiB/s):

| Channels within one file | Per-connection cap, RAM | Per-connection cap, disk | Shared cap, RAM | Shared cap, disk |
| --- | --- | --- | --- | --- |
| 1 | 8.00 | 7.98 | 8.00 | 7.98 |
| 2 | 15.98 | 15.82 | 8.00 | 7.95 |
| 4 | 31.92 | 31.26 | 8.00 | 7.96 |
| 8 | 63.77 | 60.95 | 8.00 | 7.95 |

All 16 combinations passed, including observed connection counts and 512 MiB
of assembled, hash-checked data. Rates are from deliberately paced local
fixtures; they are not predictions of a user's PikPak download rate.

## Live comparison on the selected original

The user selected `Pack From Shared/test_large_file` in their PikPak account
(3,594,972,444 bytes). On September 14, 2026,
`examples/measure_download_channels.rs` downloaded the same first 128 MiB with
1, 2, 4 and 8 channels, followed by 8, 4, 2 and 1. Each channel requested a
different non-overlapping piece. All requests used the app's direct HTTP client,
the original download URL and the saved desktop account profile.

| Channels per file | Combined measured MB/s | Average seconds per 128 MiB sample | Speed relative to one channel |
| --- | --- | --- | --- |
| 1 | 2.22 | 60.43 | 1.00× |
| 2 | 4.04 | 33.18 | 1.82× |
| 4 | 5.15 | 26.08 | 2.32× |
| 8 | 8.83 | 15.19 | 3.98× |

Here MB/s means 1,000,000 bytes per second. Combined rate is total sampled bytes
divided by total elapsed transfer time for the two runs at each channel count.
The two eight-channel results were 9.95 and 7.94 MB/s; the single-channel results
were 2.33 and 2.13 MB/s. Eight channels were faster in both test orders.
An app similarity helper overlapped the test; its bandwidth use was not measured
or isolated. These are observed rates under the current network conditions.
Reversing the order reduces, but does not eliminate, background-traffic and
CDN-cache effects.

The CDN returned valid `206` ranges and a strong ETag. Every sampled byte range
matched its requested boundaries, and all eight assembled samples matched the
same SHA-256 baseline. This transferred 1 GiB of measured sample data into RAM;
it did not download the whole original, inspect media, add app transfers or alter
the remote file. URL resolution occurs outside the transfer timer. Connection
setup, response waiting and body receipt are included; hashing is outside it.
No signed URLs, credentials or file contents are written to the results log.

This demonstrates a benefit from direct parallel ranges on the tested route.
It does not establish whether the single-connection bottleneck is a provider
policy or network behavior, or promise the same rate for every original. The
similarity analysis pipeline and external-disk writes were not timed here.
For this route, trialling up to eight channels per large original is justified,
with the existing overall connection/RAM bounds and provider backoff intact.

To repeat the live measurement after explicitly selecting a test original,
pass an owner-only JSON plan to the example:

```sh
python3 scripts/with-client-credentials.py cargo run --release --locked --example measure_download_channels -- /private/path/plan.json
```

The plan contains `account_directory` (the existing app account directory) and
`target` with the selected file's `id`, `name` and `size`. It contains no token or
signed URL. The example uses the desktop OAuth profile and the app's locked
refresh-token store, stops on changed identity/ranges or service errors, and
limits each trial to three minutes. Inherited proxy settings are disabled by
the client. This diagnostic is separate from production pause/resume handling.

Optional `channels` lists the exact trial order, and `sample_bytes` selects the
same prefix length for every trial. The defaults retain the original
`[1, 2, 4, 8, 8, 4, 2, 1]` comparison and 128 MiB sample. The diagnostic validates
its plan before authenticating: at most 16 trials, 1–128 channels per trial,
8 MiB–1 GiB samples, and at least 1 MiB per piece. These are diagnostic resource
bounds, not published PikPak connection limits. It also records the negotiated
HTTP version without logging addresses or signed URLs.

### Follow-up above eight channels

On September 14, 2026, a follow-up on the same selected original planned
`[8, 16, 32, 64, 64, 32, 16, 8]`. Both attempts used direct HTTP/1.1 and returned
valid range probes with strong ETags.

The first attempt used a 512 MiB sample, giving each of 64 channels an 8 MiB
piece. Its first eight-channel trial ended with a body-transfer error before
completion. During that attempt, a separate app helper was receiving about
16 MB/s, and a separate three-second physical-interface observation measured
about 17.5 MB/s. This was not an isolated network test; these observations do
not establish the cause of the transfer error.

A single shorter attempt used the original 128 MiB sample size:

| Planned channels | Outcome |
| --- | --- |
| 8 | One complete sample in 58.28 seconds: 2.30 MB/s |
| 16 | An HTTP 503 response stopped the comparison |
| 32 and 64 | Not attempted after the service error |

The eight-channel sample validated its ranges and established a hash baseline.
No higher-count sample completed, so this attempt provides no successful
cross-count integrity comparison or higher-channel speed measurement. The
diagnostic stopped all its remaining requests after the error and did not retry
the 503 or advance to 32/64 channels. Existing app transfers were not controlled
by this diagnostic.

[HTTP 503](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.6.4) reports
temporary service unavailability; one occurrence is not evidence of a fixed
16-connection PikPak limit. This result supports measuring benefit while
respecting provider backoff, rather than assuming that each increase improves
throughput. There is still no verified rate above eight channels on this route.

## Integrity, pause and resume

A one-byte probe must return an exact `206 Content-Range` and a strong ETag.
Every subsequent range uses `If-Range`, validates its boundaries, total size,
length and validator, and rejects encoded bodies. Ignored or invalid ranges
fall back to sequential validation. Bytes from changed originals are never
joined. See [RFC 9110, Range Requests](https://www.rfc-editor.org/rfc/rfc9110.html#section-14)
and [If-Range](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5).

Disk data with gaps lives in `.part.ranges.data`; its versioned
`.part.ranges.json` journal records each piece's accepted prefix and completed
EOF. The file's apparent length is never proof of completion. Writes are
buffered by piece, flushed and synced before an atomic journal update, normally
once per second and on pause/interruption/completion. Completed pieces survive
retries of a different piece. A missing EOF causes at most the final byte of that
piece to be revalidated after restart. Full coverage is required before the
staging file replaces the legacy `.part` and is finalized by the existing code.
An older app therefore never sees a sparse range file as a complete legacy part.

Validated legacy prefixes can migrate into the range journal. Unverifiable
journals cannot certify data: only an independently validated legacy prefix can
be retained in that case. A changed or incompatible source keeps only the
contiguous prefix for full sequential verification. Both the engine and native
queued-cancellation path remove the owned staging data and journals after the
writer stops, including when no legacy `.part` remains.

Similarity pieces occupy one anonymous RAM mapping with independent byte
coverage. Readers receive it only after every piece has completed. The existing
RAM reservation includes committed data and receive-window headroom. A RAM
waiter drops its HTTP bodies before waiting for more memory, so the shared
connection allowance cannot deadlock against unfinished originals.

Pausing parallel similarity downloads releases their connections and retains
the mapping and piece offsets. Resume requests the missing bytes; a network
retry does the same. Clearing/cancelling releases the mapping. Similarity
originals remain RAM-only: an app/helper restart reuses completed analysis
checkpoints, while unfinished RAM originals must be fetched again. Normal disk
piece progress survives helper/app restart.

## Implementation validation

The regression fixtures use generated localhost data, not cloud originals.
They cover range/ETag rejection and sequential fallback, a connection dropping
while other pieces finish, disk restart in a separate process with a full-length
sparse file containing holes, disk pause/resume and changed originals, cancel
cleanup, retained RAM on pause/retry, RAM-wait socket release and crash release
of shared connection slots. Controller simulations verify growth beyond eight
and rejection of an unhelpful higher count. The native transfer tests also cover
cancellation when only the new staging siblings exist.

```sh
python3 scripts/with-client-credentials.py cargo test --locked --lib -- --test-threads=4
python3 scripts/with-client-credentials.py cargo test --locked --bin pikpak -- --test-threads=1
scripts/build-native-test.sh scripts/TransferControlTests.swift /tmp/mycloud-transfer-controls
/tmp/mycloud-transfer-controls
```

Validation on September 14, 2026: 184 library tests and 84 CLI tests passed
(five CLI tests remained ignored), and the native transfer-control checks
passed. The macOS bundle built successfully, passed strict signature
verification, and was installed and relaunched as 2.2.25 (build 200). Installed
app and engine executables matched the packaged artifacts. Saved shared
transfer documents were preserved across the restart.

The live experiments above informed the design; their rates are not a promise
of end-to-end production throughput. No further live escalation was performed
after the higher-channel comparison returned HTTP 503.

## Other options

Multiple direct channels on the current internet connection are the first
candidate. They can help with limits on an individual connection and do not
require a tunnel or proxy. A shared link or account-wide cap remains a cap.

Changing the route through a tunnel can help an inefficient international path,
as PikPak's announcement notes, but needs a comparison on the same original.
The user's preference remains direct connections. Do not enable a proxy based
on the synthetic results. Combining independent internet links is a separate
network setup change; creating additional tunnels over the same uplink does not
create additional physical uplink capacity.

The completed 1/2/4/8 comparison established eight as its fastest tested count.
The higher-count follow-up was inconclusive after a service error. Admission now adapts to changing bandwidth within the shared resource budget;
eight is not a fixed per-file maximum.
