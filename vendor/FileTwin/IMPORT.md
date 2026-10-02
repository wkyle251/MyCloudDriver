# FileTwin source import

Updated on 2026-09-09 from the app owner's FileTwin workspace, commit
`6a01a40c228d741b5e1568e2c1af87f35c03fd49` (version 0.2.0-dev).
`UPSTREAM-SHA256.json` records the unmodified committed source snapshot. Only
tracked source, schemas, examples, build scripts and public documentation are
included. Credentials, indexes, scan results, model binaries and build outputs
are excluded. The upstream working repository is not modified.

## MyCloudDriver adapter

FileTwin 0.2 replaces the catalog/job/matrix API with `Encoder::encode`, progress
callbacks, per-path `FileRecord` values and portable `VectorFile` results.
MyCloudDriver calls this API from `src/similarity_encode.rs`, bundles the matching
`filetwin-worker`, and saves immutable comparison snapshots itself. Comparisons
use FileTwin's cosine function only within identical profile IDs. Unavailable or
incompatible measurements remain unavailable, never zero. Each file occurrence
keeps an app ID distinct from FileTwin's content ID, so identical copies and
hardlinks remain separate selectable files. SHA-256 is the separate exact-copy
evidence.

`src/similarity_scope.rs` discovers selected roots through descriptors without
following symlinks. The app's local addition, `EncodeSource` and
`Encoder::encode_sources` in `api.rs`/`engine.rs`, accepts a blocking supplier
called only when a native worker slot is available. Each source has a unique
relative result key, an absolute original path and an optional owned lease.
Leases are released per result; on cancellation, native children stop before
remaining leases are dropped. One invocation retains the worker pool throughout
the scan. The additional `Encoder::encode_stream`/`EncodeSourcePoll` API
distinguishes a temporarily empty queue (`Pending`) from its end (`Complete`),
so workers continue returning results while discovery is still running.
`src/similarity_discovery.rs` feeds a bounded 128-entry metadata channel from a
separate cancellable producer. Native providers append a private JSONL inventory
as files are found; PikPak feeds each listing page before fetching the next.
No originals are prefetched by discovery. `tests/native_contract.rs` verifies
bounded acquisition, worker reuse, live discovery, cancellation and per-input
cleanup. Directory-based `Encoder::encode` remains
compatible. These additive changes are local to this import; the upstream
workspace and source snapshot hashes remain unchanged.

The September 10 concurrency fix adds `EncodeSource::deferred` and the parallel
stream scheduler in `src/pipeline.rs`. Hosts now queue a resolver with metadata;
resolution, complete-file hashing and UTF-8 encoding run in bounded input
workers. Fetching, reading and encoding share the configured slot limit.
Native decoders retain one reusable pool. Verified duplicate occurrences attach
to an in-flight content/profile result without holding a processing slot or
retaining their temporary original. Shared staging reservations and native
memory reservations bound concurrent work. Readers can request a larger memory
allowance on retry, borrowing idle allowance without exceeding the shared
budget. Progress has an additive optional `work` object with real phase counts.
The directory API and vector/profile formats remain compatible. The separate
upstream FileTwin workspace has not been modified.

Binary prefixes no longer fall through to the UTF-8 reader. Unsupported content
and invalid/insufficient text retain exact-copy hashes, with no fabricated
vector. MyCloudDriver retains sanitized per-file error codes/stages/reasons in
the saved matrix and uncapped aggregate reason counts in the scan summary;
the interface distinguishes unsupported content from failures. Runtime logs,
credentials and private decoder paths are not copied into these diagnostics.

Local files are passed directly without an extra host copy. PikPak originals
are downloaded on demand. Native iCloud/Photos providers receive a selected-ID
request and atomically return a private JSON reply with the resolved original
path. Only the request's private lease directory is deleted; local and iCloud
originals are never removed. Legacy batch limits are accepted but unused.
Content-type and hidden-file choices remain host filters. The content sniffer in
`src/similarity_format.rs` is copied from this revision's `scan.rs` under the
upstream license; its classifier must stay aligned when importing new formats.

Encoding uses reusable workers and native memory admission with hardware-derived
defaults or user-selected limits. Models stay loaded throughout the scan. The
private `filetwin-vectors.f32.zst` cache retains validated content/profile vectors
as losslessly compressed float32 data (see `docs/SIMILARITY_VECTOR_CACHE.md`);
FileTwin rereads and hashes current bytes before reuse, including renamed files.
Cache storage is bounded; it is an acceleration, not the result inventory.
Progress reports files discovered, queued, active, encoded and reused while
discovery and analysis overlap. The total becomes known at discovery completion.
An app-owned compatible-pair comparison phase follows when both finish.
The host provides an existing private temporary parent. Worker temporary/cache
environment variables point inside the disposable invocation directory; FileTwin
checks cleanup before emitting its terminal progress event.
Cancellation returns available inventory and exact evidence even if comparisons
have not started. Temporary copies are removed before completion is reported.

`src/similarity_store.rs` publishes new snapshots under `runs/mcd2-*.sqlite3`.
Readers can still query the old `index.sqlite3` format read-only; there is no
migration or deletion of older scans. `src/similarity_groups.rs` forms strongest-
first complete-link groups from the saved scores. Changing 5–100% thresholds
reads saved measurements without opening originals or running encoders.
Each new scan retains up to four million compatible scores; larger or cancelled
runs explicitly report incomplete comparison coverage. The app's existing
inventory and summary bounds still apply.

Native assets are provisioned explicitly at build time. Preserve
`LICENSE`, including its required notice, and `THIRD_PARTY_NOTICES.md` plus
downloaded component notices in distributed apps. These are bundled in Resources.


### MyCloudDriver 2.2.18: CoreML RAM admission and wait reasons (2026-09-11)

Memory-scheduled CoreML visual capacity derives from the analysis allowance and
host OS capacity, replacing the fixed legacy accelerator_workers limit. Stable
visual slots still bound idle model caches, and per-file reader/decoder bytes
must fit before dispatch. Legacy hosts retain their explicit accelerator limit.
Progress adds defaulted waiting_accelerator and waiting_worker counts; a ready
file reports waiting_memory only when its own reservation cannot fit. Contract
tests cover more than two visual jobs, concurrent CPU documents, preserved legacy
limits, exact wait reasons and changing RAM/OS capacity. Native profiles and
checkpoint backend compatibility remain unchanged; upstream is untouched.

### MyCloudDriver 2.2.17: memory-based admission (2026-09-11)

Added optional `EncoderConfig.memory_scheduling` for the streaming API. Analysis
reservations now admit readers and decoders by estimated bytes rather than a
fixed host worker preference. Reader copies remain charged at exact byte size;
decoders may retry with larger allowances. Read/decoder reservations are released
before waiting for another pool, and fit-and-reserve is atomic. WorkCounts adds
a defaulted memory_scheduling flag. The legacy admission path, native protocol
and vector profiles remain compatible. The app's progress adapter reports
analysis-reserved bytes separately from original staging. Tests cover mixed
reader costs, full-pool retry liveness and small-file progress. The upstream
checkout and recorded upstream source snapshot remain unchanged.

### MyCloudDriver 2.2.10: originals in memory (2026-09-10)

Added a host-owned in-memory EncodeSource, optional memory staging for local
native inputs, and protocol-v4 read-only RAM transport with HTTP byte-range
support. Raster/PDF/DOCX readers consume seekable memory; FFmpeg uses the local
transport without disk caching. Original buffers are released on result,
cache reuse, error and cancellation. Tests cover RAM transport, duplicate reuse,
cancellation, and native readers. This is a vendored integration patch; the
upstream FileTwin checkout is unchanged. Encoding profile IDs remain unchanged.

### MyCloudDriver 2.2.11: independent acquisition (2026-09-10)

The app now supplies completed sources from its bounded RAM queue; downloads
and provider waits run outside FileTwin's analysis slots. Core progress adds a
defaulted `WorkCounts.ready` count for read inputs awaiting a native worker (a
subset of the existing memory-wait count). Native dispatch chooses the oldest
input that fits free memory, avoiding head-of-line blocking by a larger input.
Contract tests cover this scheduling behavior without exceeding the shared
allowance. Protocol v4 and encoding profiles remain unchanged. No edits were
made to the separate upstream FileTwin repository.

### MyCloudDriver 2.2.12: separate originals and decoder budgets (2026-09-10)

Original RAM staging now reserves a single original copy. The native pool
reserves its possible reader copy in addition to the decoder's allowance, and
dispatch/retry admission includes both. Initial allowances include copy costs,
large inputs can still borrow remaining shared memory, and an original larger
than the analysis pool fails explicitly instead of waiting indefinitely.
Initial decoder allowances use 64 MiB bands, so small differences in original
size do not invalidate the native worker's model cache. Reader copies retain
exact byte accounting inside the shared analysis budget.
`WorkCounts.original_memory_bytes` reports local RAM staging with a default for
older progress decoders. A contract test checks that two 512 MiB decoders plus
their input copies cannot overcommit a 1 GiB analysis budget. Native protocol
v4 and vector profiles are unchanged. The upstream checkout remains unchanged.

### MyCloudDriver 2.2.13: incremental recovery callbacks (2026-09-11)

`Encoder::encode_stream_observed` adds a completion callback for each file record.
The host commits derived records and source revisions before progress advances;
callback errors stop the pipeline instead of losing the recovery checkpoint.
Existing encoding APIs retain their behavior using a no-op callback. The host
also checkpoints the comparison matrix and retries transient network failures.
Originals remain in RAM and are released on pause. Native protocol v4 and vector
profiles are unchanged; no changes were made in the upstream FileTwin checkout.

### MyCloudDriver 2.2.14: CoreML admission (2026-09-11)

The host selects the existing upstream CoreML profiles after an in-memory
runtime probe, or retains CPU profiles. EncoderConfig adds accelerator_workers
(default two) and an optional host-owned compiled-model cache directory. The
streaming scheduler bounds visual jobs to a stable set of worker slots, keeping
idle CoreML model count bounded as well as active jobs. CPU document/audio jobs
can use other slots and all jobs share the analysis-memory allowance. Progress
adds accelerator_active / accelerator_limit. The native request protocol and
encoding profiles are unchanged. Native contract tests cover concurrent CPU
work and reuse of the limited visual worker set. Upstream remains unchanged.

### MyCloudDriver 2.2.20: host-owned original buffers (2026-09-11)

`MemoryInput::from_buffer` accepts an owned, immutable byte view without copying
it into another Vec. The existing `new(Vec<u8>)` and retained-budget guard APIs
remain compatible. MyCloudDriver uses anonymous memory mappings with incremental
RAM grants and predictive download admission. Seekable readers and loopback
transport retain the final buffer owner until decoding ends. A core test verifies
byte identity, seeking and final-owner cleanup. Native protocol v4 and vector
profiles are unchanged. No edits were made to the upstream FileTwin checkout.

### MyCloudDriver 2.2.21: cooperative pause

Local-only integration adds a per-encoder pause flag and live scheduling resource
updates to `CancellationToken`. The streaming pipeline stops dispatch while
paused, retains queued sources and their leases, and drains already executing
work. Analysis settings change after that work drains; readers use the new
configuration and impossible reduced budgets fail without deadlocking. This is
not an upstream FileTwin change.

### MyCloudDriver 2.2.24: live RAM admission

The streaming pipeline now applies RAM changes without waiting for active
decoders to finish. Native slots resize in place, retaining busy processes and
their original leases; obsolete idle slots retire safely. Reader capacity grows
with the new allowance. Queued and newly completed reads are checked against the
current budget, and new work waits if existing reservations exceed a reduced
limit. Progress and terminal events report the applied allowance. Deterministic
CPU/CoreML tests cover growth, shrink, retained inputs and continued queue progress.
This update is confined to the vendored integration.

### MyCloudDriver: overlapping RAM reader requests (2026-09-12)

The loopback memory transport serves up to eight concurrent requests per
original, all sharing its immutable buffer. FFmpeg can now open a replacement
range request before closing its previous response, without blocking behind
that unread response until the HTTP timeout. Reader threads are bounded, reaped
after completion, and joined on shutdown before the original's reservation is
released. Saturated endpoints return a prompt 503 instead of accumulating work.
Regression tests cover overlapping ranges, stalled headers/bodies, saturation,
capacity recovery and cancellation. This transport fix leaves native protocol
v4, encoding profiles and compatible cached vectors unchanged; it does not
modify the upstream checkout.

### MyCloudDriver: password-required document outcomes (2026-09-12)

Explicit ZIP password-required errors and PDFium's password error now use the
existing `unsupported_format` code with the `password` stage. Malformed documents
remain decoder failures. MyCloudDriver journals confirmed exclusions by source
revision to prevent repeated original downloads. Native protocol v4 and encoding
profiles are unchanged, so the helper and already-running compatible workers can
exchange these outcomes without a protocol migration. Upstream is unchanged.

### MyCloudDriver: original RAM handoff (2026-09-12)

Completed originals move from host download/local staging reservations to
analysis reservations when encoding starts. The destination is reserved before
the source allowance is returned, and the analysis lease follows the immutable
buffer through its last reader. Decoder retries keep originals accounted for
and return them to the download queue when space permits. Exhausted retry queues
report a RAM shortage instead of deadlocking. FFmpeg reads no longer reserve a
second full-file copy; image/document readers retain their real copy allowance.
Protocol v4, encoding profiles and compatible cached vectors remain unchanged.
This is a local integration change, not a modification of the upstream checkout.
