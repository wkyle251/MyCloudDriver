# Automatic recovery audit

Audited the application's operation families on 2026-09-26, including the Swift task owners, Rust request/transfer helpers, and native torrent engine. Recovery belongs to the task owner: a bounded request retry inside a helper must either return to an owner that retries or report a condition requiring user input.

`AutomaticRecovery` uses 5, 15, 30, 60, 120, then 300 seconds repeatedly. There is no attempt ceiling. Existing transfer engines retain their shorter backoff and provider cooldowns. Successful progress resets the appropriate delay. Retrying does not change configured concurrency or bypass storage, source-integrity, account, or destination checks.

| Operation | Recovery owner and behavior |
| --- | --- |
| PikPak downloads | Rust retries transient per-file requests and refreshes signed URLs. Dynamic refreshes an expired Guest URL once and retries temporary Guest metadata failures before considering User access. Swift retains unfinished requests and restarts interrupted helpers, including exits without a final error event and failures while launching. Destination volume identity and write access are checked before starting and while running; disconnected disks wait without creating a replacement folder under `/Volumes`. Durable partial checkpoints resume after the original disk returns. Repeated disk errors use backoff; rereading the same prefix does not reset it. Available destinations can continue while another waits. Full disks remain eligible for retry. Provider cooldowns and paused folder-child identities are preserved. |
| PikPak uploads | Swift retries saved batches, including launch failures and unavailable source disks. Rust upload checkpoints reconcile completed cloud files before continuing. Source identity/size checks remain mandatory. |
| Saved transfer state | Failed writes retry using the current queue snapshot. Unreadable/corrupt saved queues are retained rather than overwritten with an empty queue. Destination volume identities, whole-batch pauses, per-file pauses, and cancellations are saved. Cancel All Downloads clears the visible and saved queue immediately and rejects late progress from the stopped helper; unavailable disks defer partial cleanup. |
| Torrents and torrent-to-PikPak relay | Confirmed engine exits, interrupted metadata requests, engine errors, and unavailable buffers schedule recovery. Relay recovery reconciles cloud receipts and fences off the previous uploader first. A lost status reply leaves an unconfirmed live writer monitored. Resume continues to validate cached pieces and the original disk/buffer. |
| Torrent queue persistence | Failed writes retry while the app is open. Explicit Pause/Stop is saved separately from interruption; interrupted work can resume after relaunch. Legacy paused queues without intent stay held unless migration can establish that they were running. |
| Saved shared-link roots | Failed roots keep retrying at the capped delay. An unavailable account waits without generating repeated login prompts. |
| Cloud extraction and folder merge | Existing remaining-work/receipt reconciliation retries without the former six-attempt ceiling. Password requests still wait for a password. Cancel and removal clear scheduled retries. |
| Folder listings and file search | Foreground listings, expanded folders, and interrupted name-search helpers retry. Account/context changes, collapse, navigation, close, and explicit cancellation supersede old requests. Native-drive listings retry temporary provider/filesystem failures. |
| Folder measurements and duplicate discovery | Interrupted read-only helpers retry. Native duplicate discovery retries temporary filesystem interruptions; unsupported or corrupt inputs remain individual reported issues. |
| Empty-folder and `.DS_Store` cleanup | Interrupted scans repeat discovery in the originally requested scope. The scanner rechecks current files/folders; it does not replay an unconfirmed deletion blindly. Cancel ends recovery. |
| Similarity scans | Checkpointed interruptions keep auto-resuming beyond the former six-attempt limit. Drive/network interruptions remain retryable. Inventory entries are acknowledged only after their write succeeds, preventing a failed append from silently skipping an item. |
| Images, thumbnails, previews, and Open downloads | Temporary reads/materialization retry until the owning task is cancelled. Streaming cache requests no longer stop after three failures. Selecting another item or closing the preview cancels its work. Invalid data, missing decoders, and external application-launch errors remain actionable errors. |
| Native-drive transfers | Transfer retries cover network interruptions, provider cancellations that the user did not request, unavailable disks, disk space/quota, and access errors. Waiting jobs release their worker slot. Completed-item tracking avoids repeating successful items in the same run. |
| Account/traffic information | Foreground quota requests and temporary management reads retry. The traffic panel already polls every minute and retains the last snapshot on failure. Rejected credentials require sign-in; they are never silently substituted with another account. |

## Download Pause and restart

Pause All and per-file Pause stop cloud reception. The helper stays alive;
accepted RAM data continues through the disk writer and synced checkpoints,
and queued verification continues through the read turns. Resume uses the same
helper when it is still running. Cancel retains its separate removal behavior.

Each download workspace prevents automatic idle system sleep while reception
is active, including server retries, and while paused downloads still have RAM
data, verification or checkpoint work to finish. Normal Quit retains this
protection until the helper has saved its data. A fully paused and drained
workspace releases its activity; other downloading workspaces retain theirs.
The display may turn off normally. Explicit Sleep and closing a laptop lid
remain subject to macOS power policy.

Normal Quit stops reception, drains accepted RAM data to disk, and waits for the
helper's successful save before closing. Restart restores partial checkpoints
and pending verification from the durable queue, preserving global and individual
pause intent. Physical RAM cannot survive a forced termination or power loss;
those cases resume from the last synced checkpoint and fetch unsaved bytes again.

Disk diagnostics separate checkpoint queue waiting from time spent saving, and
record payload writes independently. Writers receive targeted wakeups and may
write up to 64 MiB sequentially per output before yielding. Each write turn
selects all currently pending RAM payload and finishes that batch without a
time limit. New cloud data continues into Pending writes for the next batch,
so arrivals cannot extend the selected batch forever. Read turns have no time deadline: unfinished checks yield at safe I/O boundaries
only when pending writes exceed 80% of the effective shared RAM limit. RAM
already selected by another disk’s writer does not count as pending. The download dashboard shows physical destination
disk read/write rates from kernel counters, refreshed every two seconds;
these include other apps using that disk and never scan download contents.

Download buffering has no fixed RAM reserve. Its allowance starts at up to
1 GiB and grows by at most 128 MiB per second while the buffer needs space and
macOS reports normal memory pressure. An optional user maximum and physical
RAM bound growth; unknown physical RAM falls back to 64 MiB. A warning lowers
the allowance without discarding queued data, remembers a safer ceiling, and
holds recovery for 30 seconds after pressure clears. Critical pressure reduces
new admission to 16 MiB. Existing payload keeps draining while the allowance
is lower than current use. Saved reserve settings and inherited reserve
environment variables no longer restrict the app's automatic policy.

HDD checkpoint requests on the same volume are grouped: up to 128 files share
two full drive-cache barriers, with at most 256 outstanding requests per
volume. Data and unpublished journals are synced before the first barrier;
journals are then published and their directories synced before the final
barrier. No caller receives a successful save acknowledgement before both
barriers finish. A cancelled caller cannot cancel a dispatched save, and a
failed barrier never acknowledges progress. Destination and file identity
checks still apply. Internal SSD checkpoints retain their existing save path.

During a write turn, payload writes take priority over a new checkpoint group;
a group waiting one second becomes eligible so recovery saves cannot starve.
An external writer can drain ready chunks ahead of its soft twenty-second save
timer, but must save after 512 MiB or sixty seconds of unsaved progress. These
are scheduling bounds; an unavailable disk or an in-flight I/O operation can
still delay a save. The 80% threshold follows any reduction in the effective RAM limit under
memory pressure; it has no minimum or maximum timer. Finished write batches
yield to readers, and a threshold already exceeded can request the next write
batch immediately. Numeric diagnostics record cumulative
group commits, files saved, cache barriers, save duration and pending requests,
alongside separate checkpoint waiting and payload-write counters.

Verification dispatch has separate admission from cloud receivers. Resumed
partials finish their saved-data checks even when every receiving slot is in
use, then release read admission before waiting for a receiving slot. The
descriptor-derived task ceiling and FIFO verification byte limits still apply.
Reducing the receiving target never aborts an existing body. A completed HTTP
producer releases its slot while its RAM consumer continues draining.
Speculative receiving ahead of saved-prefix checks uses at most eight active
HTTP receivers and, independently, at most 64 unverified contexts. EOF, error,
or cancellation returns the HTTP allowance immediately; verification activation
also returns it if the body is still receiving. The context allowance remains
until verification activates the payload or the context is dropped. Sequential
HTTP bodies also own their endpoint/channel permit and fairness participation;
these return at body completion rather than during later disk work. All queued
payload continues to share the configured RAM byte limit; no per-context RAM
reservation is added. Owner markers survive receiver completion while accepted RAM still needs
prerequisite reads and disk drain. An ended empty body drops its drain marker:
ordinary Pause still runs its check, while normal Quit can leave that check in
the durable queue without waiting for a read that has no RAM to save.
Anonymous counters distinguish occupied early-receiving slots, unverified
contexts, receiver completions, failures, and zero-byte endings. Exhausting the
separate context limit takes the normal check-before-receiving path. A read
turn's elapsed clock starts after the preceding writes drain, for diagnostics
only. Temporarily unready selected work retains the turn. When its cohort
finishes below the threshold, waiting checks join the reader without a write
handover. When no verification remains, even a small RAM tail and checkpoints
drain; pause/cancel/shutdown can also request draining. Unread bytes return to
pending at a threshold handover without losing read/hash progress. Numeric
activity diagnostics include receiving-slot waits and read-handover cause,
elapsed milliseconds, remaining selected bytes, pending-write bytes and the
effective limit at that decision. Handover reason codes are 2 (all reads
finished), 4 (pause/cancel/shutdown drain), and 5 (pending writes above 80% RAM).
Verification uses one sequential stream per rotating disk with two bounded
1 MiB buffers: one may be hashed on a blocking worker while the next is read.
The read turn covers actual I/O, and an in-flight read finishes before the gate
is released. Full final read-back, source proofs and before/after file identity
checks remain mandatory. These scratch buffers do not replace or enlarge the
shared download RAM budget.

Parked writers do not each poll the disk queue. One coordinator watches the
idle/locality clock; an active I/O completion wakes the next eligible writer.
If checkpoint priority or a cohort handover displaces that notified writer
before it is polled, it forwards the wake to the new coordinator before
parking. An idle disk cannot leave every eligible writer asleep.
Control-file changes wake parked writers for cancellation or normal Quit,
without scoped-control lookup or file refresh inside the disk queue mutex.
Normal Quit also selects the finite remaining RAM tail for draining. Numeric
diagnostics include cumulative writer dispatch polls and eligible queue counts.

Ranged coalescing buffers retain the original compact network allocations and
their shared RAM charges until physical output succeeds. Moving a chunk from
the receive queue into a writer does not refund its RAM allowance. Only the
admitted physical writer assembles a contiguous disk batch; per-file waiting
buffers do not allocate another full receive window. Checkpoint coverage still
becomes durable only after the existing data and journal barriers succeed.

Ready verification tickets are checked before scoped controls during dispatch;
queued cancellation is still scanned whenever a Cancel control exists. A
receiving-slot release wakes only the FIFO head rather than every waiting
receiver; cancellation and increased capacity wake the next eligible receiver.
Anonymous diagnostics distinguish preparation after admission, FIFO queue
waiting, the initial reader gate, per-chunk turn waiting, read I/O including its
blocking-pool dispatch, hashing itself, and scheduler dispatch passes. Timers
may overlap; they are not physical disk busy-time percentages.

Codes 1 (deadline) and 3 (RAM pressure) remain readable in older logs. Observed handovers are stored separately
from throughput windows; the Activity Log describes the last handover using
integer seconds. Rich summaries retain up to 192 numeric fields within the
existing 16 KiB record and eight-day/128 MiB history bounds.

## Conditions requiring intervention

Automatic retry cannot supply a password, grant macOS access, replace corrupt input, install a missing decoder/helper, or make a provider accept a permanently rejected link. These checks stay visible and are never bypassed. Storage-related waits continue automatically when the original resource becomes usable. Download destination conflicts are repaired automatically under the output lease: mismatched regular files are deleted, damaged staging and its checkpoints are reset, and staging whose source-bound checksum still matches is kept. Cleanup rejects symlinks, directories, changed roots and another transfer's ownership; unavailable access keeps retrying.

Cloud create/share/move/delete actions without a durable receipt or reconciliation contract are not blindly replayed after an ambiguous reply. Native-drive operation closures are not a durable relaunch journal: an application exit still requires reviewing/restarting those operations. Durable relaunch recovery covers PikPak transfers, torrents, and checkpointed similarity scans. Extending native relaunch recovery requires persisted operation descriptors and receipts, especially for Photos imports.

## Verification

Failed download files keep retrying automatically, including while other
files in the same folder are still running. The delay grows through 5, 15, 30 and 60 seconds;
longer service cooldowns still apply.

A failed file belongs in Retry, not Failed, unless its failure can never clear. The helper
names a permanent cause only when the account says the file does not exist (deleted or
moved), the cloud path now holds a different file, the content link reports it gone (HTTP 404
or 410), or refreshed original content exceeds its declared size. Local destination and staging conflicts remain retryable and are repaired
automatically. Invalid Guest byte ranges preserve verified checkpoints, refresh Guest
once, then use User access for that file in the same run rather than repeating the
malformed response indefinitely. An oversized Guest response also switches to User
access. Known oversized Content-Length responses are rejected before reading the
body; streaming overruns invalidate completion checkpoints so a truncated original
cannot be published on the next attempt. If User content remains oversized, the
app moves the file to Failed with its reason after three consecutive matching
reports instead of repeatedly downloading the whole file. For other permanent
causes, the app also moves a file to Failed only after three consecutive
attempts report the same cause, so one stray 404 or a listing that lags behind never writes
a file off. Throttling and outages (429, 5xx), expired links, network errors, a full or
unplugged disk, permissions, a changed source, a signed-out session and every unrecognised
error keep the file in Retry with its last error and the reason it is waiting (for example
"Paused" or "Waiting for sign-in"). A different failure, a completion, Retry or Retry All
starts the count again, and a final failure still has a Retry button. A row saved without
its source details cannot be retried on its own, so it goes to Failed saying so. The
progress card no longer shows a failed count; its file count includes only files that are
finished, and a file waiting to retry is not finished. Once a whole batch finishes with nothing failed, the status bar keeps a short
report of it; a batch with a failed file is not reported until that file is resolved. Retries preserve their destination and
resume data, and explicit Pause or Cancel holds or removes the saved selection.

Restored per-file Pause controls also hold their file selection before it is
submitted to the live helper. The pending row uses the same pause check as queue
admission and shows Paused with a Resume action. Known file sizes are displayed
before admission; a restored retry adds its saved size to the estimate until
discovery supplies the exact total.
When the helper acknowledges a new attempt for the same source and local
destination, its older failure row leaves Retry immediately. A failure at
another destination remains independent, and a new failure replaces the old
error instead of appearing beside an active download.
Estimated Remaining includes an approximate duration while discovery continues.
Before a measured network rate is available it explicitly says Calculating time;
the first usable rate replaces that placeholder with the estimated duration.
Saved failed-child retries also carry their original folder ancestry into the
download helper after restart. A proven retry can reclaim its own partial
under the destination lock while the folder is still being discovered; active
file bodies, paused ancestors, unrelated selections and cyclic ancestry remain
protected.

A reformatted download disk (for example ExFAT restored onto APFS at the same
path) has a new volume identity, so the saved queue no longer matches it. This
is reported as a replaced disk, not as an unplugged one, because waiting can
never end it. The queue continues without asking when this app's own progress
files for the queued items (`.part`, `.part.resume.json`, `.part.ranges.json`)
were restored at the exact place their download continues; the proof scan is
bounded and file-specific, and a different disk that lacks those files never
receives the download. Otherwise the panel offers **Use This Disk**. Accepting
a disk moves the saved identity of every queued folder on the old disk to the
new one and saves it, so a restart does not ask again. Resume itself does not
depend on the file system: checkpoints record checksums, not device or inode,
so a copied `.part` or range map is verified by content before it is reused,
and a `.part` restored without its checkpoint restarts rather than trust
unproven bytes. Partial cleanup keeps its strict identity check and never
deletes on an unproven disk.

A finished download restored from a backup is a new file: it has a new inode and
new times, and its hidden `.myclouddriver-downloads` receipt may not have been
restored with it. Its bytes decide whether it is the download. A committed
receipt follows the file when the size and the receipt's SHA-256 match, and is
rewritten for the new identity. Without a receipt, a file whose size and PikPak
GCID equal the source's `gcid:` revision is recorded as the completed output.
A time-based or unknown revision, another size, or other bytes are preserved
and reported as before, a same-size file is never assumed to be the original,
and nothing is ever replaced. Verification reads the file once and follows
Pause and Cancel.

Skipping a finished file is metadata-only whenever the receipt can vouch for it.
A committed receipt vouches for a file of the same size and modification time:
the same file object additionally needs its change time unmoved, because any
write moves it even when the modification time is put back, while a copy, which
has a new inode, keeps only its size and modification time as Finder, `cp -p`
and rsync do. That check runs before a download link is requested, using the
size, hash and modified time from the folder listing, so a finished file costs
neither a network request nor a read, and writes nothing to the destination
disk. Its limit is stated plainly: bytes altered without changing size or time
are not noticed, and an edit through a normal program always changes the time.
A copy with another time, or one without a receipt, is read in full (the
receipt's SHA-256, or the cloud's GCID); the downloads panel then shows
**Verifying N files · P%** where the speed would be, since nothing is
transferred meanwhile, and the receipt is rewritten once so it is not read again.

ExFAT volumes may lack exclusive rename and hard links. Download finalization
then copies the already downloaded original locally into an exclusively created,
journaled destination. The original stays available until the verified copy
commits; this requires additional free disk space. Interrupted copy prefixes
resume only after their recorded identity and checksum are verified.
Timestamp-only changes are accepted after byte verification; modified or
replaced files remain preserved. Synced copy checkpoints record the identity
of the continuously held writer after validating its current path and length.
A source-bound pending copy with an outdated destination identity can recover
an already complete output only after independently verifying both full
checksums; it does not overwrite that output. ExFAT can also change an empty
file's identity when its first written allocation is synced. Legacy copies
stopped at that point use a separate, bounded recovery check: filesystem type,
initial creation metadata, the source-bound original checksum, and every byte
of the existing copy prefix must agree before its journal can be rebound.
Incomplete copies with uncertain ownership remain preserved at their existing
path. When a source-bound publication journal and the full retained staging
checksum prove the completed download, recovery publishes a separate,
exclusively created sibling file. The source-bound receipt records that route
before creation and its owned copy checkpoints afterward, so interruption or
restart continues the same recovery. An unowned candidate left by an
interruption is preserved and a fresh candidate is selected. Completion and
Finder actions use the recovered file's actual path; the original download
name and retry selection remain unchanged. A rejected copy
reports retained download progress only after the full staging checksum and
its publication pointer have been independently verified.

When parallel range downloading falls back to sequential downloading, an
internal staging rename or truncation requires a fresh checkpoint checksum
and identity check before the saved prefix is reused. A parallel attempt that
leaves staging unchanged keeps its existing proof. Dynamic downloads retain
the verified Guest prefix while switching to User access for the remainder.

Download lists construct and map at most 50 rows per section page while all
queued work continues in the background. Normal rediscovery after restart does
not rewrite the already saved selection or helper controls for every file.
New inherited Pause/Cancel controls and actual queue changes still persist
immediately.
Waiting retries appear in their own Retry section and return to Downloading
when their next attempt is admitted. Their saved bytes remain in the aggregate
progress, while backoff does not count as an active download or hold a worker.
Automatic failed-file retries use the same section; failures requiring attention
remain in Failed. Each section retains its independent 50-row pagination.
Folder discovery is bounded so large selections do not fill memory with every
file at once. Until discovery finishes, byte and file totals describe the files
discovered so far, including skipped files. The dashboard withholds the overall
percentage and ETA during that period. A usable cached measurement for a single
undiscovered folder is shown separately as a cached estimate, rather than used
as an exact download denominator.
Normal transfer-output publication is batched at 250 ms intervals, preserving
every ordered event while reducing list redraws. Pause and Cancel write controls
immediately, and process completion drains outstanding updates without waiting
for the next display interval. Unchanged speed samples, transfer status and
progress totals do not publish additional view updates; real rate changes and
stalled speeds still update normally.

Run `zsh scripts/test-automatic-recovery.sh` after building the app resources. It compiles one fixture executable and runs recovery, torrent, native transfer fairness, download, shared-link, transfer-control/persistence, preview, thumbnail, folder-expansion, and similarity suites. Test payloads are generated in temporary directories. It does not inspect the user's downloaded payloads.

Regressions cover an outage exceeding the backoff schedule, unexpected helper/provider exits, disk errors, retry cancellation, account isolation, explicit pauses across relaunch, receipt preservation, and safe torrent destination checks. Download checkpoints verify retained local bytes before reuse; checksum creation is incremental during transfer, and restore reads retained regions once. Overlapping selections cannot cancel another live or paused selection's partial. A terminal failed child releases ownership for an explicit retry even while other files keep its original folder active. Pending-root Pause is saved even while its disk is unavailable, and control-write retries follow the active helper independently of preview navigation.
