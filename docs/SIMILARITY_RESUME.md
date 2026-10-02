# Resumable similarity scans

Scans expose Pause, Resume, Cancel and Clear in the scan window and Status.
Closing the scan window pauses active work and keeps the scan. Cancel stops
work but retains a resumable checkpoint. **Only Clear deletes a saved scan and
its result matrix**; it never deletes the original files or shared vector cache.
Completed results remain in Saved Scans across window closes and app restarts.
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

During cloud acquisition, **Cloud download progress** uses bytes of file content
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

The cloud progress bar also shows an estimated download time: remaining content
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

Each scan has its own checkpoint under its existing drive/account data folder.
Completed inventories are sealed as ordered, individually compressed database
rows, so Resume has neither a 100,000-file ceiling nor the old aggregate 256 MiB
JSON decode ceiling. Per-record validation and memory/download budgets remain.
Resuming an older sealed inventory that reached the former file/listing limit
rediscovers the full scope using its saved per-file analyses. Its expanded
inventory receives a separate comparison checkpoint, preserving the old scores
without attaching them to different file ordinals. An active older helper needs
an app restart and Resume to use the expanded discovery policy.
No credentials, signed download URLs or original content are checkpointed.
Completed per-file vectors and source revisions are written transactionally as
files finish. In-app Resume continues the existing helper and inventory, retaining
partial and ready originals in RAM. After a helper/app restart, Resume inventories
the scope again, reuses unchanged completed files, and retries unfinished files. Changes in source revision invalidate reuse.
Once analysis finishes, comparisons use that saved inventory and resume from
the last committed range of pairs. A process lock prevents two windows from
resuming the same checkpoint simultaneously.

Downloads remain RAM-only. Pause and Cancel now stop admission cooperatively;
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
cannot strand a download behind connections that need its memory. Photos retains
the same FIFO, buffer and provider task; paused time does not count toward its
provider timeout. No original is checkpointed to disk.

Clear stops the helper, cancels providers and releases all buffers. Actual app
shutdown or a helper crash necessarily releases volatile RAM; completed vectors
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
Changing Processing in Scan Resources applies only to new scans. While running,
**Pause & Adjust Resources…** pauses the helper and opens the editor after its
pause is acknowledged. RAM admission and the progress display update in place,
including while paused. Active decoders retain their processes and original buffers;
queued files can start under the new allowance on Resume without waiting for every
old decoder to finish. If existing reservations exceed a reduced allowance, new
analysis waits until those files release enough RAM. An already paused scan exposes
**Scan Resources…** directly. The editor starts with this scan's saved Analysis
RAM and Download RAM amounts. **Save** keeps it paused; **Save & Resume**
continues immediately with the new allowances. Cancel leaves it paused with its
previous limits.

The session descriptor is updated atomically before Resume. Edits reject a
running helper, a stale session ID or invalid memory split. Resume reads the
descriptor's resource limits, not app-wide preferences; another window changing
defaults cannot silently change this scan. Reducing or increasing RAM allowances
preserves completed analysis and committed comparisons. Legacy worker limits
are ignored when a saved scan resumes with memory-based admission. Downloaded originals
remain in RAM when limits change. Download RAM cannot shrink below the amount
needed for a safe completion order of retained partials. Impossible analysis
reservations report a resource error instead of waiting forever.
Restoring Automatic derives amounts from current hardware while preserving the
scan's original processing mode. Only Clear removes the checkpoint and results.
