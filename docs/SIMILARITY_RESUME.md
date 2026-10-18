# Resumable similarity scans

Scans expose **Pause**, **Resume** and **Finish Scan** in the scan window and
Status. Pause retains the helper, downloads and queued originals in RAM. Closing
the scan window also pauses and keeps the scan.

**Finish Scan** stops new acquisition and analysis, lets files already analysing
complete, then compares completed files and opens a saved report marked
**Finished early**. It also works while paused. Unfinished disk reads and provider
requests do not delay the report. The report supports the existing selection,
comparison and Move to Trash actions. **Resume Scan** continues its checkpoint,
reusing unchanged completed analysis and fetching unfinished originals again.
Opening a saved report does not start the scanner or require its disk to be online;
resuming or changing source files requires the original drive/account.

**Delete Report** removes the saved scan record and its result matrix. While a
scan is active or paused, **Delete Scan** discards its progress and results.
Neither action deletes original files or the shared vector cache. Completed and
user-finished reports remain in Saved Scans across window closes and app restarts.
Older cancelled scans remain readable and resumable.
Closing a browser window leaves its open Find Similar Files window and helpers
running. The account and drive providers remain owned by that scan window;
revealing a result reopens its original browser. Closing the last scan window
after its browser has closed ends that workspace and saves progress for recovery.
Quit always saves and stops scans, including those without a browser window.
New Scan and Scan Again retain the previous scan in that history. Saved scans
remain scoped to their original drive/account when accounts are switched.
Selecting **Scan drive** refreshes that drive's Saved Scans, just as opening the
window does. In particular, opening from Home on Local Disk and then selecting
PikPak reveals its paused scans without closing and reopening the window.

The Active scan time counter stops when Pause is accepted, and continues from
the saved duration on Resume, including after Quit. Reports use the cumulative
active duration. The session descriptor saves it on pause/completion and at most
every five seconds during progress, so recovery excludes time while the app was
closed. Older descriptors retain the duration between their start and last save;
their historical pauses cannot be reconstructed.

The recovery descriptor also saves a bounded progress snapshot: analysed,
unsupported and failed counts, scores, newly analysed/reused counts, cumulative
downloaded/read/hashed bytes, byte progress, resource telemetry and the displayed
download queue. It is written atomically with the timer/settings every five
seconds while running, immediately on Pause/acknowledgement and Quit, and when
in-flight analysis finishes while paused. Idle paused telemetry is throttled.
An unreadable/newer snapshot is ignored without hiding the saved scan itself.

Resume restores the summary cards before the helper catches up with its saved
files. Live RAM usage, speeds and active queues restart from zero after an actual
helper exit; the snapshot never claims volatile buffers survived Quit. Same-helper
Resume retains those buffers and does not add its transfer counter twice. A new
helper adds new traffic to the saved cumulative total. Resuming a sealed comparison
does not add the historical report's downloads again. The per-file checkpoint
keeps the original newly-analysed/reused classification across cache replay.
Older sessions remain resumable; transfer totals discarded before this feature
cannot be reconstructed exactly.

During complete-original cloud acquisition, **Cloud download progress** uses bytes of file content
ready over the inventory's total file size. It includes every active partial
download, including rows omitted from the bounded display, and counts cached,
excluded and otherwise finished acquisition work once. Retry traffic and header
probes affect the separate Downloaded total but cannot inflate the percentage.
Metadata discovery can count ahead of the RAM queue without a file-count cap.
Cloud and streamed provider metadata use a private temporary disk queue; original
contents remain in their existing RAM pools. Until counting finishes, the denominator is labelled
as found so far and the bar stays indeterminate. Once cloud data is ready, analysis
may still finish; comparison progress continues to use pairs. Local analysis
continues to use file counts.

For complete-original transfers, the cloud progress bar also shows an estimated
download time: remaining content
bytes divided by the helper's smoothed aggregate download speed. It waits for a
complete inventory and fresh speed telemetry, uses all transfers (including rows
outside the visible list), and excludes cached/skipped content from the remaining
size. Pause suspends the estimate; a helper restart waits for a fresh speed.
Stale or zero speed displays “Estimating download time…” instead of a countdown.
The estimate covers downloads; analysis and comparison may continue afterward.
Durations use months (30 days), weeks, days, hours and mins, with no seconds.
Only unit values greater than one appear; a single larger unit carries into the
next smaller unit, so 1 hour 30 minutes appears as 90 mins. A duration under two
minutes displays “Less than 2 mins”.

Supported PikPak audio/video may fetch sampled original ranges during analysis.
Those transfers report actual fetched bytes and range-read states; the amount
needed depends on the container and decoder seeks, so they have no whole-file
percentage or download ETA. A sampled read is not recorded as a complete
original download or a full-file SHA-256 pass. Completed vectors remain reusable
through trusted GCID, original size and exact analysis profile within the same
account, including across different cloud file IDs.

Each scan has its own checkpoint under its existing drive/account data folder.
Completed inventories are sealed as ordered, individually compressed database
rows, so Resume has neither a 100,000-file ceiling nor the old aggregate 256 MiB
JSON decode ceiling. Per-record validation and memory/download budgets remain.
Resuming an older sealed inventory that reached the former file/listing limit
rediscovers the full scope using its saved per-file analyses. Its expanded
inventory receives a separate comparison checkpoint, preserving the old scores
without attaching them to different file ordinals. An active older helper needs
an app restart and Resume to use the expanded discovery policy.
PikPak discovery and each validation pass overlap up to eight independent
metadata requests per helper, including direct selected-file validation.
Pagination within a folder remains sequential, and provider retry delays are
shared with other requests. Complete inventories are still checked both before
and after comparison; concurrency shortens those passes without treating an
incomplete or failed listing as proof that files disappeared. Checking progress
reports completed/queued folders, pages and files, including empty folder trees.

No credentials, signed download URLs or original content are checkpointed.
Completed per-file vectors and source revisions are written transactionally as
files finish. In-app Resume continues the existing helper and inventory, retaining
partial and ready originals in RAM. After a helper/app restart, Resume inventories
the scope again, reuses unchanged completed files, and retries unfinished files. Changes in source revision invalidate reuse.
Once analysis finishes, comparisons use that saved inventory and resume from
the last committed range of pairs. Exact float64 score chunks and their
canonical progress cursor commit together; resume does not reread every saved
score merely to count completed work. Old row-based checkpoints are converted
transactionally only after file-axis and exact-score validation against the
saved vectors. Interruption rolls the conversion back to the previous format.
Older published snapshots remain readable. There is no fixed comparison or
qualifying-edge limit; exhaustive comparison still has quadratic time and disk
cost. A user-finished, unsealed inventory receives
a fresh comparison matrix on Resume, so scores cannot be assigned to new file
ordinals; completed per-file analysis is still reused. A process lock prevents two windows from
resuming the same checkpoint simultaneously.

Downloads remain RAM-only. Pause stops admission cooperatively;
the helper, partially received originals, completed RAM queue and provider pipes
remain alive. Work already analysing may finish and save its vector, releasing
that original normally. Resume uses the same helper; it does not repeat discovery
or download completed originals. Closing the scan window also retains its helper.
Use New Window to start another scan while keeping this one in RAM.

HTTP response futures stop polling during pause. If a connection closes, a strong
ETag and validated Content-Range allow a byte-range continuation. A server without
safe range support may retransmit the prefix; it is verified against retained RAM
before new bytes are appended. Changed originals are never joined across versions.
Partial buffers keep their connection entitlement during retries so their RAM
cannot strand a download behind connections that need its memory. Seekable
media also retains its admitted block cache and scan transport entitlement.
Pausing cancels its current HTTP attempt before waiting, retains completed
blocks, and retries the unfinished block on Resume. Native range decoder
deadlines exclude paused time. A helper restart releases those volatile blocks;
finished derived vectors remain reusable. Photos retains
the same FIFO, buffer and provider task; paused time does not count toward its
provider timeout. No original is checkpointed to disk.

Finish releases unfinished originals after draining active analysis, and keeps
the derived checkpoint for explicit Resume, without automatic recovery. Provider
cleanup runs after its writers stop, independently of publishing the report.
Deleting an active scan cancels the helper, with a force-stop deadline if it is
blocked in filesystem I/O. Actual app shutdown or a helper crash necessarily
releases volatile RAM; completed vectors
and comparisons survive in the checkpoint. The UI distinguishes live RAM retention
from this restart recovery.
Temporary network/server errors retry with capped backoff and Retry-After,
while ready local analysis continues. Authentication/access failures remain
actionable instead of silently becoming successful scans. Abrupt process exits
leave the last committed checkpoint available after reopening the drive.

Implementation order: durable per-file callbacks and checkpoint storage;
resumable comparison writing; transient network recovery; persisted session
descriptors and provider scope restoration; shared Pause/Resume UI; interruption,
revision, account-isolation, native-decoder and UI verification.

The processing backend is pinned when a scan starts. Automatic checks CoreML
with a synthetic in-memory image, then selects CoreML or CPU before acquiring
user originals. Resuming keeps that selection, including older CPU checkpoints.
Processing Options applies only to new scans. RAM admission is automatic for
new scans and recovery, and the app exposes no RAM editor. Old manual amounts
are ignored while the checkpoint's processing backend stays pinned.

Pause retains partial downloads, queued originals and active analysis leases in
the same helper. Resume continues those buffers without reacquiring them. The
automatic governor rebalances admission without discarding data or overriding
the user's Pause. Shrinkage can leave held reservations above a current soft
allowance; new work waits while existing analysis drains. A temporary reduction
does not turn otherwise admissible queued files into failures. Files that cannot
fit with their decoder inside system capacity report a resource issue.

The session descriptor is saved atomically before Resume. Completed analysis
and comparisons remain reusable across automatic allowance changes. Legacy
worker limits are ignored. Only Clear removes the checkpoint and results.
