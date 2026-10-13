# Similarity originals in memory

MyCloudDriver uses RAM for its own similarity-scan originals. This applies
to full-resolution originals; thumbnails are still not used for matching.

- PikPak: resolve a fresh download URL, reserve RAM, then stream into a bounded
  buffer. Retry drops the incomplete buffer; it never creates an original file.
  Confirmed password exclusions are reused before resolving or downloading an
  original. New ZIP candidates receive small encryption-header probes before
  original-memory admission; inconclusive probes fall back to normal analysis.
- Apple Photos: PhotoKit's data callbacks write into a private, nonblocking
  FIFO, which the helper drains into an admitted RAM buffer. The FIFO is an IPC
  entry with zero file size; content is held in memory, not in the filesystem.
  Cancellation interrupts backpressure and closes both ends.
- Local Disk/iCloud: read the selected file through a verified descriptor.
  Supported originals, including text, get a stable RAM copy, with revision
  checks on the source. At most four files are copied concurrently. Hashing
  runs separately after acquisition, in Analysis RAM, so slow disk/network
  reads cannot occupy every analysis worker.
- FileTwin: memory sources bypass temporary-file staging. Images, PDF and DOCX
  use memory readers. Audio, video and HEIF/AVIF use a private read-only loopback
  endpoint with HTTP range support, so seeking needs no media scratch file.
  Overlapping requests use independent readers sharing the same immutable
  original. A decoder's unfinished response cannot block its next seek. Each
  original permits up to eight readers; excess requests fail promptly instead
  of starting unbounded threads. Shutdown joins every reader before returning
  the original's RAM reservation.
  The endpoint accepts only its random path, disables response caching, and
  stops before the final original reference is released. Decoders cannot use
  playlist demuxers or FFmpeg's disk cache protocol.

**Download/Read RAM** reserves incoming and queued original buffers. Before
hashing starts, **Analysis RAM** reserves the original plus calculation/decoder working
memory before returning the original's Download RAM reservation. This handoff
keeps the same buffer and frees download capacity immediately. The original's
analysis lease stays with the buffer until its last reader drops. Their calculated total accepts the Mac's full
physical RAM (64 GB on a 64 GB Mac). A 64 GB total with 12 GB Download RAM leaves
52 GB for analysis. Downloads reserve small windows as bytes arrive. Native
reader copies are included in the prepaid analysis allowance.
Images and documents that use `open_input()` need a complete worker-side copy;
FFmpeg video/audio and HEIF/AVIF readers seek the shared original and need no
second full-file copy allowance. Plain UTF-8 also reads the original directly.
Memory-based admission starts text/documents at 128 MiB, and
visual/media decoders at 512 MiB. These stable initial decoder allowances preserve
model reuse across slightly different input sizes. A decoder requesting more
memory retries with a larger allowance; original and reader-copy bytes remain
exact. The read reservation is released before hashing. Decoder retries retain
their original in Analysis RAM rather than moving it back into Read RAM.
Known sizes and recent speed predict new starts; every window also passes a
Banker's safety check under the original-buffer limit. Unknown-size Photos
originals start with one eighth of Download RAM as their enforced capacity, so
the eight native preparation workers can overlap. On overflow, the provider
closes its attempt and reports a minimum capacity; the helper releases the
partial buffer and retries with a larger allowance, capped by the pool. Only
receive windows are reserved initially. Generic unknown-length streams still
claim the whole allowance and admit one unfinished stream at a time.
Unused claims are released at completion. Oversized originals report a RAM-limit reason with
an instruction to increase Download RAM. There is no disk fallback.
Existing preferences without a download budget use one quarter of the total,
capped at 12 GB; the prior total is preserved. Legacy worker and batch settings
remain readable but do not constrain new or resumed app scans.

Starting with 2.2.11, cloud acquisition has its own pool of producers.
Discovery sends metadata to that pool; a producer reserves RAM, finishes the
download, and puts the original into a ready queue. FileTwin admits only ready
sources into its read/hash/analysis slots. Slow downloads, retries and original
RAM waits therefore consume no analysis slots. PikPak connections start at up
to four and trial higher concurrency when the RAM forecast has room. A trial
is retained only when aggregate network throughput improves by at least 10%,
up to 64 connections. Unhelpful trials drain without interrupting retained
partials; provider 429/5xx responses reduce admission and enforce cooldowns.
Connection capacity is separate from RAM. Waiters retain neither a connection while awaiting initial RAM nor
RAM while awaiting a connection. Smaller files in a bounded lookahead can progress
while larger originals wait. The lookahead has at most 128 producers.
PikPak's ready queue is limited by original bytes, independently of the worker
count. A 100,000-entry ready queue applies backpressure while the encoder is
busy; it never skips files or truncates discovery. Pending cloud/provider
metadata is spooled to a private temporary file, with no scan file-count cap.
Path-based providers keep a small metadata queue without pre-reading files.
Those paths are counted as waiting to read, not ready for analysis.
Waiting originals remain in Download RAM. Originals already being analysed
belong to Analysis RAM, alongside that file's decoder and required copies. No batch must
finish or fill before analysis starts. Native decoder admission selects the
oldest ready file that fits available memory, so a large waiting file does not
hold up smaller inputs that fit.

For path-based scans, **Read RAM reserved** includes each native file's full
size reserved before the read begins. A full reservation does not mean the file
has already arrived in RAM. Reading and hashing have separate counters.
Completed originals move to Analysis RAM before their first hash read.
**Download speed** measures bytes arriving from the source (including external
and network disks), excluding hashing RAM, decoder reads and file completions.
It remains visible when the processed-file counter has not increased.

Progress shows reserved Download RAM in GB, its configured capacity, free
capacity, the remaining analysis budget, and a separate downloading-file count.
Reserved Download RAM covers incoming/queued originals and small receive windows, not measured
process RSS or cumulative bytes transferred. The Downloads to RAM list shows
individual progress, speed, remaining time and wait/retry states. Progress also separates waiting to read, fully acquired originals ready for analysis, reading, hashing,
analysis, connecting, retries, and RAM waits. **Analysing** counts hashing and encoding work
only, without a worker quota. **Analysis RAM reserved** includes handed-off
originals and admitted processing allowances; source throughput, hashing, cache hits and decoder RAM can all lower
the active count. These are estimates for admission, not a hard RSS ceiling;
cached models and shared pages may use additional memory. The general queued total includes ready originals
and other waiting files; the ready count is a subset of that total.

Buffers and their reservations are released after encoding, vector-cache reuse,
unsupported content, terminal failure, Finish or Delete Scan. Pause and
transient retries keep originals alive. Duplicate result waiters
retain metadata only. Native workers and their descendants stop before their
originals are released. Finish drains already analysing files and abandons unfinished acquisitions.
Blocked OS reads are not joined indefinitely; their workers retain private
inputs/directories until they return, or the helper exits. A stopped helper
cannot leave an orphaned memory server process or disk original behind.

The promise is about application-owned **content copies**, not zero system I/O:
macOS can swap memory, and iCloud/Photos can materialize or cache originals within
their managed libraries. The application does not disable those system features.
Vector caches, comparison databases, scan metadata, FIFO directory entries, and
model/runtime caches still use storage. User-requested Downloads and Open With
are separate operations and retain their normal storage behavior.

The vendored FileTwin change uses native protocol v4; install the helper and
worker together. Encoding profiles are unchanged, so compatible saved vectors
remain reusable. Standalone FileTwin retains its default disk-staging API;
`memory_staging` is available on `encode_sources`/`encode_stream`, and directory
`encode` rejects that option rather than silently writing a source copy.

Validation covers bounded memory admission, retry and failure cleanup, transport
range reads, native-worker input storage, duplicate reuse, cancellation, and a
synthetic Photos pipe handoff. Personal Photos access is not required by tests.

## Queue liveness audit

The download and analysis pools have a one-way dependency: acquisition reserves
receive windows under a Banker's safety check, sends complete originals to the
ready queue, and analysis
releases it. No analysis job waits for discovery to finish, for another download
to finish, or for more bytes from the original pool. Network metadata permits
are released before waiting for RAM. Analysis reader copies use the separate
analysis allowance. A file too large for either allowance is reported instead
of being admitted into a wait which can never succeed.

Retries retain incomplete buffers and their connection entitlement through
backoff, avoiding a disconnected partial blocking connected files that need its
RAM. Empty attempts release both. Pause keeps the helper and buffers alive. A dropped request also releases both, even without a global cancel
signal. Cancellation is checked while waiting for RAM, transport capacity,
retry delays and queue space. If the encoder returns early (including a failed
checkpoint write), dropping acquisition stops its producers before releasing
the remaining queued originals. Duplicate results retain metadata only.

The regression tests feed the real FileTwin consumer from a full RAM queue in
legacy mode and with memory-based admission. Mixed known and unknown sizes, cache reuse,
unsupported inputs, oversized originals and impossible decoder budgets must
all terminate and return every reservation. Separate fixtures interrupt a
download while another waits for its entire RAM allowance, and interrupt
checkpoint persistence with a full queue. A watchdog outside both queues makes
a failure to advance terminate the test rather than hang the test runner.

These checks cover the scheduler's own waits. They do not make a slow network,
an offline provider or a memory-starved operating system complete immediately.
The UI must keep those states distinct from files that are ready for analysis.

See [Memory-based analysis admission](SIMILARITY_MEMORY_ADMISSION.md) for the
2.2.17 scheduler, resource controls and migration details.

See [Predictive downloads](SIMILARITY_PREDICTIVE_DOWNLOADS.md) for the 2.2.20
forecast, hard buffer grants, connection growth and progress list.


## Pause retention (2.2.21)

[Pause and recovery](SIMILARITY_RESUME.md) describes the live helper lifecycle.
Pause stops download consumption and new analysis admission without dropping RAM
leases. The download list remains visible with its retained byte counts and paused
rates. Resource edits resize the same download budget and reconfigure analysis
at a safe boundary. Shrinking Download RAM must preserve a safe completion order;
this uses the existing Banker calculation, not just current received bytes.
Clear releases all memory; actual application/helper termination still requires
refetching unfinished originals because original bytes are never written to disk.
