# Rolling download concurrency

Status: implemented, tested and built as MyCloudDriver 2.2.27 (build 202).

## Intended behavior

Normal, shared-link and similarity downloads continuously evaluate the most
recent five seconds of aggregate received bytes, updating at most every 500 ms.
Replace the fixed 30-second delay after an unhelpful trial with fresh, stable
measurement windows. Downloads and queue admission continue while measuring.

## Implementation steps

1. Replace disjoint samples with a bounded rolling history. Exclude idle time,
   pauses, byte-counter resets, resource changes and draining trial connections
   from decision baselines. Require a complete five-second window; compare its
   halves to avoid reacting to transient bursts. Preserve the 10% gain threshold
   and a two-second settling period after changing concurrency.
2. Keep a failed trial's observed baseline. Reconsider promptly after a stable
   fresh window, with progressively more evidence required for repeated failures
   on an unchanged link. A sustained rate change clears that plateau history.
   Sampling continues throughout; server Retry-After remains authoritative.
3. Coordinate file-count and per-file channel trials through one download trial
   coordinator. Share its generation and expiring ownership across app helpers
   using the existing private download-connection directory. Other controllers
   discard windows spanning another trial. A stopped or crashed helper cannot
   retain trial ownership indefinitely. Existing transfers continue normally.
4. Connect both normal file admission and similarity admission to the same
   process-wide original-byte counter used by channel trials. Keep uploads in
   their own measurement/coordinator scope. Preserve the 64-request budget,
   range verification, disk journals, RAM admission and queue fairness.
5. Add deterministic simulated-time coverage for sliding windows, burst noise,
   a changed bandwidth ceiling, repeated plateaus, pauses, stalls, RAM pressure,
   draining, counter resets and controller coordination. Add generated loopback
   coverage for real range growth and verify existing disk/RAM retry regressions.
6. Run the Rust library and CLI suites, build the release app, update the
   implementation documentation and record the results here.

## Scope and validation boundaries

The rolling window and timings are starting values to verify, not a claim of
optimal PikPak throughput. Coordination removes simultaneous deliberate trials;
ordinary file completions and external network traffic can still affect speed.
Cross-helper ownership is shared; byte counters remain local to each helper.
All tests use generated data or loopback HTTP. No saved cloud scan is resumed.

## Completion evidence

- `cargo test --locked --lib`: 206 passed, zero failed. Two isolated child tests
  are marked ignored for direct invocation and exercised by their parent tests.
- `cargo test --locked --bin pikpak`: 84 passed, zero failed. Six direct-invocation
  child/benchmark entries are marked ignored; required child tests run through
  their parent tests.
- After adjusting the generated range fixture, all 13 library tests matching
  `range` passed again. Both disk and RAM admission fixtures use isolated helper
  counters and prove growth before their initial originals finish.
- The paced range test starts another channel from real HTTP body measurements,
  stops the transfer and verifies the complete generated 64 MiB original after
  resume, without fetching accepted coverage again.
- Cross-helper ownership tests cover temporary file-lock contention, retained
  release requests, stale leases, crashed-write repair, and symlink rejection.
- Review also fixed two boundary cases: fair share caps the trial itself, and
  idle/resource transitions cannot shorten a server-backoff period.

Validation logs on the development machine:
`/tmp/pikpak-rolling-lib-tests.log`, `/tmp/pikpak-rolling-bin-tests.log`,
`/tmp/pikpak-rolling-range-tests.log` and `/tmp/pikpak-rolling-app-build.log`.
`dist/MyCloudDriver.app` passed strict deep signature verification, version
verification and a packaged-engine startup check. The artifact/source hashes
are recorded in `/tmp/pikpak-rolling-artifact.json`. The app was subsequently
installed and restarted. Transfer state and checkpoint availability were
verified, with the previous app and checkpoint backup retained for recovery.
No automatic scan-resumption behavior was added.
