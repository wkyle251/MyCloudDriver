# Memory-based analysis admission (2.2.17)

Scan Resources has two amounts: **Analysis RAM** and **Download RAM**, displayed
in GB. Editing either preserves the other; the calculated total cannot exceed
the Mac's physical RAM. Automatic retains the hardware-derived RAM defaults.
Pause & Adjust Resources, Save, and Save & Resume retain their existing behavior.
Changing RAM does not invalidate completed vectors, comparisons or the pinned
processing backend. Only Clear deletes a scan.

New and resumed app scans send `memory_scheduling: true`. Saved `workers` and
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

Initial decoder allowances are capped by available configured memory after
original and reader-copy costs. A native decoder can request a larger allowance
and retry. Its previous decoder/copy reservation is released, while its original
remains accounted for. The original returns to Download RAM if that queue has
room; otherwise its Analysis RAM lease remains until retry or completion. Both
transitions reserve the destination first, so no original is ever unaccounted for.
If all work is waiting and retained originals prevent any retry from fitting,
one input reports an actionable RAM shortage to let the others drain. Requests
that cannot fit the whole Analysis RAM pool fail without waiting indefinitely.

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
both a pause and forced helper termination, even without the original files.
Handoff tests exercise logical 40/24 GB budgets without allocating GB of fixture
data, refill downloads while decoders run, verify retry backpressure/deadlock
handling, and retain the analysis lease until every reader has stopped.
