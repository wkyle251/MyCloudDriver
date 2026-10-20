# Memory-based analysis admission (2.2.17)

App scans automatically rebalance Download/Read RAM and Analysis RAM under one
pressure-aware allowance. Processing Options selects the backend; RAM has no
user control. Old saved manual amounts are ignored. The allowance starts small,
grows on demand, and pauses acquisition under system pressure without discarding
held originals. Temporary reductions preserve queued files. Only Clear deletes
a scan; its backend remains pinned so completed vectors stay compatible.

New and resumed app scans send `memory_scheduling: true` and `automatic_memory: true`. Saved `workers` and
batch fields remain compatible but no longer define scan concurrency. FileTwin's
legacy mode remains available to other hosts. Only the vendored package changes;
the independent FileTwin checkout remains untouched.

The streaming scheduler admits work from a shared analysis-byte allowance:

| Stage | Initial reservation |
| --- | --- |
| Read and hash | 1 MiB, after the original-buffer reservation is acquired |
| UTF-8 text and documents | 128 MiB |
| Images, video and other media | 512 MiB |
| Original handed over for analysis | Its download/staging reservation, transferred without copying |
| Image/document reader's original copy | Exact original size, in addition to the original and decoder |
| FFmpeg audio/video/HEIF/AVIF and UTF-8 original copy | None; reads the shared original |
| Verified PikPak range original | One admitted RAM block and scan transport entitlement; extra blocks use spare capacity |

Initial decoder allowances are capped by available configured memory after
original and reader-copy costs. A native decoder can request a larger allowance
and retry. Its previous decoder/copy reservation is released, while its original
remains accounted for in Analysis RAM until retry or completion. Automatic
admission waits for needed capacity up to the physical resource ceiling, rather
than failing when a temporary soft allowance is small. Both source banks reserve
a safe completion path through reader copies and decoding. Fixed-budget hosts
retain their original explicit shortage behavior.

Live download and staging allowances may be zero while pressure drains held
originals. Actual reservations still count, but an unused source bank contributes
zero bytes, so a ready input can use an exact-fit analysis allowance. New reads
wait cancellably for capacity; unknown-size streams wait for a positive allowance
before choosing their bounded claim. Initial encoder configuration and analysis
allowances retain their positive minimum.

If a warning persists after all held work has drained, the scheduler funds the
smallest waiting native read and its completion headroom. Only one original may
enter this recovery lane; its source bank closes before the analysis handoff.
After that file finishes, the next can proceed without waiting indefinitely for
the warning to clear. Critical pressure still stops new acquisition.

Reading releases its allowance before a decoded input enters the ready queue.
Reading never holds analysis RAM while waiting for original RAM; this prevents
a cycle in which an original cannot be released because its decoder cannot run.
Each dispatch reserves the original and processing bytes, then hands over the
original, choosing the oldest ready input that fits. A concurrent read winning
the reservation makes dispatch retry later. A 40 GB Download / 24 GB Analysis
split can refill the whole 40 GB download queue while up to 24 GB of originals
and processing allowances belong to analysis. Total reservations remain bounded
by the two configured pools; they do not force actual RSS to fill all 64 GB.
Larger waiting inputs therefore do not block smaller ready inputs that fit.
Completion, reuse, failure and cancellation release the associated reservations.

Verified PikPak audio/video may be acquired as a seekable original instead of
a complete RAM buffer. Its independently evictable range blocks stay charged
to Download RAM during analysis; the decoder has its own Analysis RAM allowance.
The first block and a scan transport entitlement are admitted together. A
waiter releases the block if no entitlement is available. An active reader
never waits for a new block reservation: it borrows immediately available spare
capacity or recycles an admitted block. Pressure reduces its target cache size.
This preserves progress when complete-original buffers already occupy the pool.
Origin-level network admission remains enforced for each request.

Progress reports the active **Analysing** count without a worker denominator and
**Analysis RAM reserved** separately from Download RAM. Allowances are estimates
for admission, not a hard process-RSS cap: model caches, runtime allocations and
shared pages can use additional RAM. Starting with 2.2.18, CoreML's persistent
visual pool scales with Analysis RAM instead of retaining the legacy two-job
limit. Its potential capacity is `analysis_bytes / 512 MiB`, bounded by the
host OS capacity; exact reader copies and larger decoder requests further limit
actual admission. Visual jobs reuse a stable set of slots so idle model sessions
do not accumulate across the whole input pool. CPU work continues alongside
them. Operating-system descriptor and process
limits still apply. The internal capacity derives from the smallest decoder
allowance and available descriptors, not the old saved worker preference.

Queue progress distinguishes memory, accelerator-slot and other processing-slot
waits. Ready inputs are checked against their own reservation cost and current
slot availability. Being in the ready queue alone no longer means waiting for
memory. Fields are defaulted for compatibility with older progress readers.

Validation covers mixed reader costs, a large retry borrowing the entire
analysis pool while originals wait for RAM, smaller inputs passing larger ones,
exact reader-copy accounting, reservation release, real image decoders and
pause/resume with changed RAM. Matrix recovery retains all comparisons after
both a pause and forced helper termination without rereading original content;
fresh scope metadata is still required for before/after validation.
Handoff tests exercise logical 40/24 GB budgets without allocating GB of fixture
data, refill downloads while decoders run, verify retry backpressure/deadlock
handling, and retain the analysis lease until every reader has stopped.

Exact comparison uses bounded CPU workers and bounded result queues, sharing
vectors rather than copying them per job. Exact float64 scores are stored in
versioned chunks, with canonical cursor/count updates in the same transaction.
Threshold grouping keeps its sorted edges, cluster links and pending merges in
private disposable SQLite tables; its page cache shrinks on memory pressure.
Neither comparison nor grouping imposes a fixed pair-count ceiling. Their total
compute and disk requirements remain quadratic in each compatible profile.
