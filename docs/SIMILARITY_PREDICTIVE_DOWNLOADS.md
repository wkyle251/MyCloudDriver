# Predictive downloads to RAM (2.2.20)

## Behavior

Similarity downloads no longer reserve an entire known-size original before
receiving its first byte. A 12 GB pool can start additional images while twelve
1 GB videos are still downloading. Admission depends on received bytes, remaining
sizes and recent throughput. This is additional overlap, not a promise that a
particular network will become faster.

Originals still move through **download → ready queue → analysis → release**.
Only complete originals reach FileTwin. Retries obtain fresh download URLs and
retain partial bytes; validated byte ranges continue interrupted responses. Since 2.2.21, Pause/Cancel keeps original buffers and the
existing helper alive; Clear or actual helper shutdown releases RAM. Restart
recovery reuses completed vectors; unfinished originals must be fetched again. Saved vectors and comparison results remain
compatible. Image analysis still uses full originals, not thumbnails.

## Algorithm

For each download, retain its maximum original size, reserved bytes and an EWMA
of received bytes/second (30% new sample, 70% previous value). Samples arrive at
most four times per second. Stale rates decay after one second without data.

The two-second forecast is:

```
forecast = all reserved original bytes
         + Σ min(remaining original bytes, recent speed × 2 seconds × 1.5)
```

New starts use a 256 KiB receive window and require forecast headroom below 90%
of Download RAM. The first stream can start even with a small configured pool;
predictions never prevent an already admitted stream from finishing. With no
samples, admission starts with a 1 MiB/s estimate, then learns from active files.
Completed originals in the queue or analysis remain charged to the same pool.

Forecasts alone cannot guarantee a bound or prevent deadlock. Every receive
window also needs an atomic grant under the **hard buffer budget**, rounded to
16 KiB pages. A single-resource [Banker's algorithm safety check](https://www.cs.utexas.edu/~EWD/transcriptions/EWD01xx/EWD108.html)
rejects a grant if all partial originals could become unable to finish:

1. Start with unused RAM.
2. Consider held originals in ascending order of remaining maximum need.
3. Each must be able to finish using that RAM, then release its current holding.
4. Admit the grant only if this hypothetical sequence can drain the whole pool.

Finished originals have zero remaining need. Waiters without a grant are not
included. Known sizes larger than the pool fail explicitly. Unknown sizes claim
the full pool until EOF, so two unbounded partial originals cannot deadlock by
both assuming the remaining RAM is theirs. This case is intentionally conservative.
Incorrectly reported originals that grow beyond their declared capacity fail
instead of overflowing the reservation.

The safety check assumes the analysis consumer eventually releases completed
inputs. That consumer has a separate RAM pool and already rejects inputs that
cannot fit; it never needs another original download to complete its own file.
An input waiting for a connection releases its tentative RAM grant immediately.
An input waiting for its first RAM grant holds no connection. These two rules
avoid a circular dependency between network slots and partial-buffer memory.

PikPak connections start at four and are capped at 64. With queued demand, a
four-second window measures aggregate received bytes. If the RAM forecast has
room, the first trial adds 25% more connections (at least two), allows two
seconds for them to settle, and measures another four-second window. After a
successful trial, the next trial doubles capacity, up to the ceiling. It keeps
the increase only for a throughput gain of at least 10%. Otherwise the previous
allowance is restored, and another trial waits at least 30 seconds and until
excess connections have drained. Existing partials keep their permits and RAM;
lowering admission never interrupts them. Admission gaps longer than one second
invalidate measurements, preventing an idle or paused queue from supplying an
artificially low baseline. Zero-traffic windows and completed files alone do not
increase the cap.

The throughput controller in `src/download_connections.rs` also drives account
and shared-link downloads to disk. The live queue uses an automatic ceiling of
64 and counts actual received body bytes separately from
existing `.part` contents. They use the same trial/settle/rollback timing without
the similarity RAM forecast. Retry delays and paused files stay queued, and
lower admission never cancels an active disk write.
An expired content link, one interrupted connection or one output-lock wait
retries only that file. Service 429/5xx failures and process-wide file descriptor
shortages still reduce the shared allowance.

The counter includes all received cloud-body bytes, even after progress rows
disappear or a request retries. Metadata and retained RAM are not counted as
new traffic. This measures network throughput; retransmissions can still make
useful file progress slower. Four-second samples are a heuristic, not a promise
of a particular download speed or an optimal connection count on every route.

429/5xx responses halve the allowance, reset trial measurements and honor
provider cooldowns. Up to 128 producers provide lookahead, allowing smaller
files to proceed around RAM waiters.
This connection ceiling is separate from the RAM limit and is not exposed as
an analysis worker setting. Photos' existing provider request pool uses the same
incremental byte grants; iCloud materialization remains managed by macOS.

## Storage and limits

Original bytes go into an anonymous memory mapping. Address space can cover the
declared file size without committing that much physical RAM upfront. Incoming
pages are committed only after receiving a grant. FileTwin retains this host
buffer directly, avoiding a growing `Vec` reallocation or a full handoff copy.
Dropping the final reader unmaps it and releases its budget reservation.
See [`MmapMut::map_anon`](https://docs.rs/memmap2/0.9.11/memmap2/struct.MmapMut.html#method.map_anon).

Backpressure stops polling the [HTTP body stream](https://docs.rs/reqwest/latest/reqwest/struct.Response.html#method.bytes_stream)
while a grant waits. Network inactivity timeouts apply when reading, not while
the scheduler waits for RAM. The limit covers application original buffers and
receive windows. It is not a process RSS ceiling: socket/TLS frames, task metadata,
models and decoder memory are separate. macOS may swap RAM, and iCloud/Photos may
cache originals in their managed libraries; the app creates no original content
file as part of this acquisition path.

## Progress design

The scan progress page has a collapsible **Downloads to RAM** section, with a
bounded, scrollable list. Each row shows name, progress, received/total bytes,
recent speed and estimated remaining time. Connecting, waiting for RAM, waiting
to connect and retrying have explicit labels. A footer shows the short-horizon
forecast next to the configured pool limit. These are current estimates, not a
guarantee about future throughput.

Rows disappear once originals enter the analysis queue; cancelled rows also
disappear. Telemetry is bounded to 128 rows, contains no signed URLs or credentials,
and replaces its previous snapshot. Non-downloading states show no speed. The
UI suppresses rates if progress stops arriving for five seconds or the scan pauses.

## Verification

- Logical 12 GB simulation: twelve 1 GB videos plus 120 0.1 GB images, changing
  arrival rates and delayed analysis; all inputs drain without exceeding grants.
- Unsafe partial-buffer growth, forecast gating, unknown sizes and cancellation.
- Slow HTTP fixture: more originals start than whole-size reservations allow,
  before any first original finishes; byte progress and nonzero speed are emitted.
- Throughput probes without completed videos; fixed-bandwidth and scalable-link
  simulations; idle/pause and RAM-pressure resets; provider backoff; connection/RAM
  waiters cannot retain both resources while waiting for the other.
- Host buffer identity, seekable readers and final-owner cleanup.
- Existing similarity pipeline, retry, queue liveness and native storage tests.
- Swift progress parsing, stale/paused rates, missing lengths and UI fixtures.
