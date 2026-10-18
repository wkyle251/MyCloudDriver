# Similarity scan resources — historical plan

Status: superseded by automatic memory admission. See
[Similarity originals in memory](SIMILARITY_MEMORY.md) and
[automatic-memory tests](TESTING.md#automatic-memory-for-find-similar) for current
behavior. The controls and proposed limits below describe the earlier design.

## Implemented controls

`macos/SimilarityResources.swift` computes defaults from logical CPU cores and
physical memory. Automatic reserves two CPU cores, assumes two inference
threads per worker, and requests at most 12 workers. Its native memory allowance
is one quarter of physical RAM, clamped to 0.5–16 GB; admitted workers are also
limited to one per 0.5 GB. An 18-core, 64-GB Mac therefore requests 8 workers and
16 GB of memory allowance. The UI uses the Mac hardware summary's memory units.

Custom accepts integer workers (1–64), decimal total memory GB (0.5 through the
Mac's full physical RAM), and Download RAM in GB. Download RAM is part of the
total; the remaining allowance admits analysis and decoder copies. Limits are captured before inventory and retained for the active
scan. GPU availability is shown, but the current backend remains CPU; GPU memory
is not additional RAM. These are capacity-based defaults, not a benchmark claim
or hard process-RSS limit.

## Demand-driven inputs (2026-09-10)

The app discovers metadata while a separate acquisition pool fetches cloud
originals into a bounded RAM ready queue. Connections grow after successful
downloads and back off on provider overload, with a separate bounded lookahead
for metadata and RAM admission. Its vendored
FileTwin `encode_stream` supplier returns a completed source after an analysis
slot frees. Downloads and retries do not occupy analysis slots, and the
downloaders continue while analysis is busy until the queue or RAM budget fills.
Local paths are read directly. PikPak originals use RAM buffers, and Photos
streams into the helper through a private pipe. Native decoder staging is also
in memory. iCloud originals are resolved by its system provider on request.
Each buffer lease is released when its result completes. Download RAM reserves
each original once by file size. Decoder copies are charged to the remaining
analysis allowance only while a native worker is active. This can lower the admitted worker count on low-memory settings.
There is no fallback to disk when an original cannot fit; scan coverage explains
that more RAM is needed. OS swap and provider-managed copies remain outside the
app's control. Cancellation stops suppliers,
kills native workers before removing their inputs, and cancels provider fetches.
The upstream FileTwin checkout is unchanged; see `vendor/FileTwin/IMPORT.md`.

One encoder invocation retains its worker pool across the scan. The app no longer
copies all selected local files, downloads all cloud originals or fills an input
batch before encoding starts. Files-per-batch and input-per-batch controls have
been removed. Their serialized fields remain readable for compatibility and are
ignored by the processing loop. Worker and memory limits still govern admission.

The sections below record the earlier baseline and optional adaptive scheduling
proposal; they are not the current input-loading behavior.

## Baseline findings before implementation

The current local FileTwin checkout and imported scheduling/inference sources
match commit `6a01a40c228d741b5e1568e2c1af87f35c03fd49`.

| Previous behavior | Evidence | Implication |
| --- | --- | --- |
| MyCloudDriver requests 2 workers and a 1 GiB native allowance. | `src/similarity_encode.rs`, `config()` | Native image/video/PDF analysis cannot use more than 2 workers. |
| FileTwin accepts up to 64 workers, further limited to one slot per 512 MiB of allowance. | `vendor/FileTwin/crates/filetwin-core/src/native.rs`, `worker_count()` | Increasing only the worker number would still leave the app at 2 slots. Both settings must change. |
| All native workers receive the same fixed allowance; pool capacity is fixed for an encode call. | `native.rs`, `Pool::new()` and `submit()` | Scheduling does not adjust to individual file costs or changing resource pressure. |
| The app prepares batches of up to 128 inputs or roughly 1 GiB before calling FileTwin. | `src/similarity_encode.rs`, `run()` | Batch size is separate from concurrent analysis. A large file can exceed a batch target and still run. There is no 27-file concurrency limit here. |
| Preparation and hashing use serial loops; plain text encoding also runs on the core thread. | `src/similarity_encode.rs`, `run()`; `filetwin-core/src/engine.rs`, `encode_file()` | More native workers alone will not accelerate every stage or file type. |
| Progress exposes completed totals, but no active-worker or memory-admission counters. | `filetwin-core/src/api.rs`, `Progress` | The UI cannot currently distinguish active encoding, preparation and waiting work. |
| The default backend is CPU, with 2 inference threads per native image worker. | `filetwin-core/src/api.rs`; `filetwin-worker/src/raster.rs` | Worker count and decoder/inference threads need a shared CPU budget. |

The inspected development Mac reports an Apple M5 Pro, 18 CPU cores and 64 GiB
of RAM. Its configuration has room to benchmark higher limits; this is not a
claim that 27 simultaneous encoders would improve throughput.

## Remaining benchmarking and adaptive scheduling proposal

### 1. Establish a measured app-level baseline

- Benchmark fresh analysis and cache reuse separately with images, text/PDFs,
  audio, video, and mixed folders. Measure preparation, hashing, encoding and
  comparison time independently.
- Use FileTwin's existing configuration to compare 2, 4, 6, 8 and 12 workers,
  with matching memory allowances. No FileTwin change is needed for this first
  improvement. Choose the fastest useful setting, accounting for UI latency,
  memory pressure, and other work; avoid selecting solely by CPU utilization.
- Initial candidates on the inspected Mac: 4–8 ordinary image workers with
  8–12 GiB total admission allowance, and fewer concurrent video or large-image
  jobs. These are benchmark candidates, not promised defaults. Keep the
  existing CPU backend and inference settings for comparable scores.

### 2. Add automatic resource planning in MyCloudDriver

- Add **Scan resources: Automatic / Performance / Custom** in scan settings.
  Automatic considers CPU capacity, memory pressure, thermal state, and other
  transfers/scans. Performance permits a larger share within the same limits;
  Custom exposes integer worker and memory ceilings.
- Reserve capacity for the interface and other active tasks. Share one scan
  budget across simultaneous local, cloud, iCloud and Photos analyses.
- Treat compressed file size as an I/O hint. Estimate decoding costs using
  image dimensions, video resolution/codec, PDF page/render dimensions and
  content type. A small compressed image can require much more memory than a
  larger text file.
- Keep preparation/download concurrency distinct from native analysis.
  Overlap bounded preparation with encoding where it measurably helps, without
  unbounded temporary copies or competing writers. Preserve source-revision
  checks, cancellation, and cleanup.

### 3. Extend FileTwin for adaptation within a running batch

- Replace equal per-slot admission with a shared budget and per-file resource
  reservations. Include reusable model/session overhead and decoder buffers;
  retain existing worker-side decoding checks.
- Let the host adjust admission targets during a run. Stop admitting new jobs
  under memory or thermal pressure, then ramp up again gradually. Lowering the
  target should let active jobs finish rather than discard their work.
- Account for thread use as well as process count. Small jobs may fill spare
  capacity; heavy jobs receive larger reservations and run with fewer peers.
  Provide fairness so a large file is not indefinitely postponed by small ones.
- Add progress fields for active/available workers, preparing/waiting files,
  reserved memory, and the reason work is waiting. Update schemas, compatibility
  tests, the app adapter, and the imported-source manifest together.
- Investigate bounded parallel hashing/text work only if the baseline confirms
  those stages are bottlenecks. Maintain deterministic file/result ordering.

This FileTwin work is required for true per-file, live adaptation inside an
encode call. App-only tuning can already select better fixed limits per batch.
The memory allowance is an admission budget, not a hard total process/GPU RSS
ceiling; observed usage and pressure must also govern admission.

### 4. Make resource use visible

Show a compact scan status such as **6 of 8 analysis slots active · 24 files
waiting**, with **Preparing**, **Analysing**, and **Comparing** distinguished.
Show measured task memory separately from the configured budget. Explain
temporary throttling, such as **Waiting for memory**. Keep this available in
Settings → Resources and the background-task status footer.

## Validation and rollout

- Compare throughput and peak memory against the existing 2-worker baseline;
  include large images, mixed media, cloud preparation, and cache-heavy runs.
- Test cancellation, low-memory/thermal transitions, concurrent scans, stalled
  decoders, and fair admission for large files. Do not add a blanket file-size
  exclusion as a scheduling shortcut.
- Confirm identical vectors/scores under unchanged encoding profiles and
  unchanged saved-score grouping. Resource tuning must not trigger rescans
  when the user changes the similarity threshold.
- Implement and test FileTwin changes in its own repository first, then import
  a reviewed revision with checksums, protocol/schema tests and app integration
  tests. Keep Core ML/GPU backend selection as a separate benchmark and review:
  it changes representation profiles and cache compatibility.

The automatic and custom controls above are implemented. Further FileTwin
changes for live per-file resource adaptation should be reviewed separately.
