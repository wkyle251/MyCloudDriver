# Similarity worker utilisation and scan coverage

Investigation: 10 September 2026, installed MyCloudDriver 2.2.5 (180).

The user approved implementation after reviewing this investigation. The
MyCloudDriver 2.2.8 implementation uses deferred originals, bounded input
workers, a reusable native pool, nonblocking duplicate waiters, shared memory
admission with larger-file retries, explicit phase counters and classified
coverage. The separate upstream FileTwin repository remains unchanged.

## Findings in 2.2.5

The following describes the original implementation, before the 2.2.8 fixes.

The scan request reaches the engine with 52 workers and a 48 GB allowance.
Neither the app settings nor FileTwin's worker-count admission reduces this
particular request to one worker. However, 52 is a maximum, and it currently
applies to the native decoder pool rather than the entire file-processing path.

Several operations still block the thread supplying that pool:

- `src/similarity_encode.rs::resolve_input` fetches one PikPak original or waits
  for one native provider to return an original before supplying the next file.
- `vendor/FileTwin/crates/filetwin-core/src/engine.rs::encode_file` reads and
  hashes the entire file, and stages native input, on the scheduler thread.
- Plain UTF-8 text analysis also runs synchronously on that thread.
- If an identical original is already being encoded, the scheduler waits for
  its result before it considers subsequent, potentially unrelated files.

Consequently, native workers can finish while the supplier is still reading,
downloading, hashing or analysing the next input. Raising the native worker
limit cannot remove these serial sections.

The app derives its "Analysing" count from admitted files minus completed files.
This includes synchronous reads/hashing and is not a direct count of native
workers currently encoding. The caption needs to distinguish these phases.

The 48 GB allowance is currently divided across 52 native slots, approximately
0.92 GB per slot. Even an idle pool does not lend unused slots' allowances to a
large file. This is a separate limitation; it did not explain the six video
failures inspected below.

## Verification

Checks used the installed helper and worker, isolated temporary directories and
separate temporary caches. The user's scan was not restarted or cancelled.

- Six distinct synthetic images reached six concurrent analyses with the
  52-worker/48 GB configuration. All six succeeded.
- Plain text takes the synchronous path independently of that native worker
  setting. Two larger synthetic text inputs reached only one active analysis
  with 52 workers requested; both succeeded. Six smaller text inputs also
  succeeded, completing between progress samples.
- The most recent saved, cancelled iCloud scan recorded 258 analysed files and
  740 failures. Of those failures, 739 were extensionless or other binary/data
  inputs, with NUL bytes or non-UTF-8 content in their resident prefixes. The
  fallback classifier labels unknown input as plain text, which then rejects
  such content. These are unavailable content comparisons, not necessarily
  unreadable files; exact-copy hashes remain available.
- One PDF in that run had a generic failure. An isolated retry with the installed
  worker and the same per-worker allowance succeeded. The original report does
  not retain enough detail to establish the cause of that earlier failure.
- Six failed MOV files from the recent local scan were reproduced individually
  with the installed worker. All returned `insufficient_content` at the media
  stage because a finite positive duration was unavailable. The current generic
  "not enough supported content" message conceals that specific reason.

The scan's "skipped" total currently combines unsupported content, access
failures and decoder failures. Only the first 500 issue details are retained;
the saved matrix does not retain the complete per-file encoder error. The UI's
discovered count can also exceed the Rust snapshot's discovered count when a
scan is cancelled with metadata still waiting in the discovery stream.

## Implementation

1. **Move the complete file lifecycle into bounded work slots.** Discovery
   continues emitting metadata. Acquire a processing slot before resolving an
   original; perform acquisition, reading/hashing and encoding away from the
   scheduler. Feed idle slots promptly without downloading the entire queue.
   Include plain text in this scheduling rather than leaving it synchronous.

2. **Preserve a single worker and memory budget.** Account for fetching, hashing
   and decoding across the same admitted files, so parallel stages cannot each
   claim another 52 slots. Start with the existing explicit memory ceiling;
   reserve memory by reader requirements and decoded dimensions, release it on
   completion, and let larger inputs borrow unused allowance. Keep streaming
   readers, cancellation, private source leases and model reuse. Keep the
   current inference profiles and comparison results compatible.

3. **Make identical-input reuse nonblocking.** Attach duplicate occurrences as
   waiters to the in-flight content/profile key. Continue admitting unrelated
   work, then publish the result to each waiting occurrence while preserving
   its original drive, file ID, path and validation checks.

4. **Separate unsupported content from failures.** Recognise binary input before
   the plain-text reader, without rejecting valid text based only on extension.
   Keep hash-only exact matching for unsupported types. Preserve structured
   error codes and safe, specific reasons per file, and keep aggregate reason
   counts even when the displayed issue list is capped. Distinguish missing
   duration, unsupported format, invalid text, memory limits, access problems,
   timeouts and worker failures.

5. **Show the actual pipeline state.** Display discovered, queued, fetching,
   reading/hashing, encoding and completed counts. Label the resource setting
   as a worker limit. Show analysed, unsupported and failed totals separately,
   with grouped coverage reasons and actionable details. A worker waiting for
   an original must not look like an active media encoder.

Changes are required in both the MyCloudDriver source adapter and FileTwin's
scheduler. Implement FileTwin changes in the vendored copy with an import note;
an upstream change in the separate FileTwin repository should be handled
explicitly so its independent consumers receive compatible API changes.

## Acceptance checks

- Slow cloud acquisition overlaps other files' analysis; discovery stays live.
- Mixed text, images and video keep available work slots occupied, within the
  requested maximum and memory budget, with no unbounded original prefetch.
- An in-flight duplicate does not block an unrelated queued file.
- Local and provider originals remain unmodified; temporary copies are removed
  after completion/cancellation. Cancel joins work before releasing its files.
- Vector reuse, source-change detection, per-occurrence IDs and saved similarity
  scores remain correct. Old snapshots still open.
- Binary/unsupported files retain exact-copy evidence without being reported as
  decoder crashes. Duration and resource failures have distinct explanations.
- Progress counters reconcile across discovery, processing and cancellation;
  reason totals remain correct for more than 500 unavailable files.
- Benchmark mixed small/large fixtures at Automatic, 16 and 52 requested
  workers, reporting throughput, peak memory and cancellation responsiveness.
  A higher requested limit should not be presented as a guaranteed speedup.

## 2.2.8 validation

The updated streaming pipeline passed 38 FileTwin core/contract/vector tests,
32 app-adapter tests, eight Swift integration check groups and the bundled
native decoder smoke checks. A separate PikPak HTTP fixture confirmed two
originals downloading concurrently under a two-slot limit. Contract checks
cover duplicate waiters, shared-budget retries and cancellation during fetch.
An inventory of 520 binary files retained all 520 exact-copy hashes and
per-file diagnostics, reported 520 unsupported files and zero failures, and
kept complete reason totals despite the 500-detail UI cap.

A disposable 58-file workload on an 18-core, 64 GB Mac produced these results:

| Worker limit | Memory allowance | Peak analyses observed | Elapsed | Process-tree RSS sum |
| --- | --- | --- | --- | --- |
| 8 (Automatic) | 16 GB | 8 | 1.29 s | 3.31 GB |
| 16 | 48 GB | 16 | 1.31 s | 6.57 GB |
| 52 | 48 GB | 49 | 2.23 s | 16.41 GB |

Each run analysed all 54 supported files, classified four binary inputs as
unsupported, and had no failures. Samples were taken every 100 ms; short
phases may occur between samples. RSS sums include shared pages and are not
a physical-memory measurement or the decoder admission allowance. This small,
CPU-heavy fixture was faster with Automatic; additional workers can overlap
cloud I/O but do not guarantee higher throughput.

The app's resource setting remains an upper bound shared by acquisition,
reading and encoding. Memory admission can intentionally lower native
concurrency for larger inputs. Invalid media without a usable duration still
cannot be analysed and now has a specific coverage reason. No user scan or
original file was changed by these checks.
