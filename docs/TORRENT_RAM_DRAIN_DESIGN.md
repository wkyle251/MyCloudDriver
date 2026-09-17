# Streaming torrent → PikPak relay: per-file drain and RAM reclaim

Status: design, awaiting approval. Supersedes the batch-at-a-time behaviour in
`docs/LOCAL_TORRENTS.md` § "Download to PikPak using RAM".

## 1. Problem

A PikPak RAM relay uploads nothing until an entire batch has finished
downloading. `refreshRelay` sets `batchReady` only on aria2's
`status.state == "complete"` (`macos/LocalTorrentRelay.swift:300`), and
`runRelayUpload` then uploads every file of `state.batches[state.batch]` at once.

Observed on a live transfer: 14,623 files / 439.85 GB, 48 GiB buffer, batch 1 of
11 sized 43.72 GB. After 3.97 GB downloaded, `0 / 14,623 files saved`. At the
measured 167 KB/s the first file would reach PikPak in ~66 hours, and any Stop
before then discards all of it.

Two further defects follow from the same structure:

- **The swarm idles** during each batch's upload phase.
- **Memory is never returned mid-job.** `ram.clear()` deletes the payload
  directory but does not detach the image, and the ramdisk's backing store only
  grows (§2). After batch 1 the high-water mark stays at ~43 GB for the
  remaining ten batches.

## 2. Evidence

All figures measured on the target Mac (64 GiB, macOS 27.0) and on aria2 1.37.0
from `.build/torrent-engine/runtime/bin/aria2c`. Probe scripts were throwaway.

### 2.1 `ram://` memory behaviour

| Step | Δ free memory |
|---|---|
| attach empty 8.59 GB image | +0.01 GB — **allocation is lazy** |
| format APFS | −0.16 GB |
| write 4.29 GB | −8.48 GB — held **twice**: backing store + APFS page cache |
| delete the file | +4.30 GB — page-cache copy only |
| `hdiutil detach` | +4.35 GB — backing store, back to baseline |

Writing 1 GB → deleting → writing 1 GB again returns to the *same* level, so
APFS reuses freed blocks and the backing store plateaus at the **high-water mark
of bytes ever concurrently resident**. Sampling noise was ≤0.03 GB.

Consequences: deletion does not shrink the backing store but does stop it
growing; only `detach` resets it.

### 2.2 aria2 1.37 behaviour

| Question | Result |
|---|---|
| Does `tellStatus` expose per-file progress? | Yes — `files[]` carries `completedLength`, `index`, `length`, `path`, `selected`, `uris` |
| `changeOption select-file` on a live download? | Accepted; `getOption` reflects it exactly, no off-by-one |
| Delete a completed file, still selected | **Recreated and re-downloaded** |
| Delete a single completed *deselected* file | **Recreated** — its pieces are shared with still-incomplete neighbours |
| Delete a contiguous *run* of completed deselected files, mid-download (33–41% complete, status `active`) | **Space kept in full, files never recreated**: +2.14 MB and +2.25 MB retained of 2.15 MB deleted, vs. a no-intervention baseline. Download completed normally. |

The fixture used 700 KB files against 1 MB pieces so that files span piece
boundaries — the same regime as the live torrent (22 MB median file, 32 MiB
piece).

**Rule derived:** a file may be removed from RAM only once every piece
overlapping it is complete *and* no still-wanted file depends on those pieces.
Scattered single-file deletion is unsafe; contiguous runs are safe.

## 3. Design

Three changes, each independently useful and shippable in order.

### Stage 1 — Upload files as they complete (no RAM change)

Poll per-file `completedLength`. When files become whole, upload them
immediately, concurrently with the ongoing download. Nothing is deleted; the
window still ends with `ram.clear`.

This alone converts "one burst every 66 hours" into "files landing every few
minutes", and it is the only stage that **applies to the in-flight transfer**
without re-planning its batches (§7).

### Stage 2 — Reclaim RAM per drained run

Once a file is committed *and* the piece-safety rule (§4) admits it, deselect it
in aria2 and delete it from the volume. RAM usage then tracks the working set
rather than the window.

### Stage 3 — Reset the high-water mark at window boundaries

Replace `ram.clear(volume)` with `release` + `acquire`. Both destroy the
payload; only the latter returns the backing store. Costs a few seconds per
window.

### Resulting pipeline

```
aria2 (one window selected)
   │  poll tellStatus(files:true) every 5 s (see note)
   ▼
completed files ──► upload queue ──► torrent-relay helper ──► PikPak
                                          │ "committed" + receipt
                                          ▼
                              piece-safety admission (§4)
                                          │
                                          ▼
                         deselect in aria2, then unlink from RAM
```

**Polling cadence.** Per-file status is read every 5 s, reusing the peer-census
cadence, not every second: a `files:true` reply for 14,623 files is ~2 MB of
JSON. At 167 KB/s a file completes roughly every two minutes, so 5 s loses
nothing. The cheap `files:false` status poll stays at 1 s for speeds and peers.

### Two queues, two triggers

The word *drain* covers two distinct steps; they are kept separate throughout.

**Upload queue** — files whose `completedLength == length` but which have no
receipt yet. Spawning the helper per file is wasteful; waiting for the window
defeats the purpose. Flush the queue when any of these holds:

- ≥ 32 completed files queued, or
- ≥ 256 MB queued, or
- the oldest queued file has waited ≥ 3 minutes, or
- the window's download completed.

The time trigger is what guarantees visible progress on a slow swarm.

**Removal set** — files that are already committed *and* pass the piece-safety
rule (§4). Evaluated after every batch of `committed` events. Removal never
gates uploading, and a file that is committed but not yet piece-safe simply
stays in RAM until its neighbours complete.

At 167 KB/s the trigger set above yields a save every few minutes.

## 4. The piece-safety rule

Torrent files are concatenated in index order, so file *i* occupies bytes
`[start_i, start_i + length_i)` where `start_i = Σ length_j, j < i` over **all**
files in the torrent, not only selected ones. With piece length `P`, file *i*
covers pieces `[start_i / P, (start_i + length_i - 1) / P]`.

A file is **removable** when all of:

1. it is committed — the Rust helper emitted `committed` and wrote its receipt;
2. every file overlapping its covering pieces is itself complete
   (`completedLength == length`) or already removed;
3. it has been deselected in aria2 via `changeOption select-file`.

Condition 2 is what makes a contiguous run safe and a lone file unsafe, and it
is computable in Swift from `LocalTorrentFile.length` plus `pieceLength` — no
extra aria2 call and no access to its bitfield.

Removal is applied to maximal runs: collect all removable indexes, delete them,
issue one `select-file` change for the remainder.

## 5. Components

| File | Change |
|---|---|
| `macos/LocalTorrentEngine.swift` | `LocalTorrentWireFile` gains `completedLength`; `LocalTorrentStatus` parses it. New `reselect(_:selection:)` on `LocalTorrentDriving` — `changeOption` without the `unpause` that `begin` performs. |
| `macos/LocalTorrentRelay.swift` | `refreshRelay` computes newly completed files; new drain coordinator decides when to spawn the uploader and which indexes to send; `runRelayUpload` takes an explicit index set instead of the whole batch; window completion skips the upload phase when everything is already committed. |
| New `macos/TorrentRelayDrain.swift` | Pure logic: cumulative offsets, piece spans, removability, run coalescing, drain-trigger policy. No I/O, no actor state — directly unit-testable. |
| `macos/TorrentRAMDisk.swift` | `recycle(volume)` = `release` + `acquire`, replacing `clear` at window boundaries. `clear` retained for the pause/stop paths. |
| `src/torrent_relay.rs` | No protocol change. It already accepts an arbitrary `files` array and writes a receipt per file. |
| `macos/TorrentRelayViews.swift` | Card shows drained/queued counts and live RAM usage rather than only `batchDownloaded / batchTotal`. |

The Swift↔Rust request contract, the receipt format and the reconcile path are
unchanged.

## 6. Persistence and rebuild safety

The user will rebuild and reinstall while a transfer is live. What survives
today, verified by reading the teardown paths:

- `shutdown()` (`LocalTorrentModel.swift:512`) pauses jobs, saves and stops
  aria2. It never calls `ram.release`; `applicationWillTerminate` calls only
  `shutdown()`. The ramdisk is kernel-owned and stays attached across quit,
  reinstall and relaunch.
- `acquire()` revalidates a saved volume by image path, device, volume UUID,
  mountpoint, filesystem type and the `.mycloud-owner` marker — none of which
  depend on the app binary.
- aria2 persists its bitfield to `.aria2` files on the volume every 5 s
  (`auto-save-interval=5`); `check-integrity=true` re-verifies on re-add.
- `queue-v1.json` lives in Application Support, untouched by replacing the
  `.app`.

Rules this design must therefore obey:

1. **Every new persisted field is `Optional`.** Swift's synthesised `Codable`
   ignores property defaults and throws `keyNotFound` for a missing
   non-optional key; `load()` then sets `storageAvailable = false` and drops the
   whole queue (`LocalTorrentModel.swift:234-235`). The codebase already follows
   this — see the comment on `LocalTorrentJob.attempted`.
2. **No rename or version bump of `queue-v1.json`** — `load()` rejects
   `version != 1`.
3. **No migration step may Stop, Restart or release RAM.**
4. A regression test decodes a captured **current-format** queue payload into
   the new structs and asserts every job and relay field survives. This runs
   before the user installs anything.

New state, all optional: `TorrentRelayState.drained: [Int]?` — files unlinked
from RAM, distinct from `uploaded`, which records files saved to PikPak.
`uploaded` and `batches` keep their meaning and encoding.

## 7. Effect on the in-flight transfer

The running job's `batches` array is already persisted, so re-planning requires
**Restart Download**, which releases RAM and discards the 3.97 GB. Therefore:

- **Stage 1 requires no replan.** It reads per-file completion inside the
  existing 43.72 GB batch 1 and begins committing files immediately. The
  existing `uploaded` set and `CloudReceipts` already guarantee a committed file
  is never fetched twice — `LocalTorrentRelay.swift:208` subtracts `uploaded`
  from the aria2 selection.
- **Stage 2 also requires no replan**, and turns batch 1 from a 43.72 GB
  high-water mark into a working set.
- **Stage 3 only takes effect at the next window boundary**, which is harmless.

Deployment for the live job: quit normally (never Stop), install, relaunch,
Resume. A smaller buffer is worth choosing for *future* torrents only — with a
1.91 GB largest file and 32 MiB pieces, a 4 GiB buffer covers this entire 440 GB
torrent, versus the 48 GiB currently reserved.

## 8. Error handling

- **Upload fails mid-window.** Files are not deleted; receipts are intact;
  Resume reconciles against PikPak before anything else runs. Unchanged from
  today.
- **Deselect succeeds, delete fails.** The file stays selected-out but present.
  It is re-admitted to the removable set on the next pass; worst case it
  occupies RAM until the window boundary.
- **Delete succeeds, aria2 rewrites the file anyway.** Detectable: the file
  reappears. Treated as a spent reclaim, not an error — the data is already
  committed to PikPak and the file is deselected, so it is never re-uploaded.
- **Volume validation fails mid-drain.** Existing behaviour: pause the job and
  surface the message; RAM data is presumed lost and re-fetched on Resume.
- **Helper reports `committed` for a file aria2 later reports incomplete.**
  Refuse to delete; log and leave it to the window boundary. The receipt is the
  authority on upload, aria2 on download; disagreement blocks removal only.

## 9. Testing

Unit (`scripts/LocalTorrentTests.swift`, new cases):

- Piece-span and removability table tests, including sub-piece files, a file
  spanning many pieces, first/last file edges, and unselected neighbours.
- Run coalescing produces maximal runs and one `select-file` string.
- Drain-trigger policy fires on each of the four conditions.
- **Compatibility:** decode a captured current-format `queue-v1.json` into the
  new structs; assert `relay.uploaded`, `relay.batches`, `relay.batch`, `volume`
  and every job field round-trip, and that absent new keys decode as `nil`.

Integration (`scripts/test-local-torrents.py --ram`, extended):

- Assert at least one file commits to the upload sink **before** the window's
  download completes.
- Assert volume free space rises mid-download after a drained run.
- Assert a drained file is absent from the volume and absent from the aria2
  selection. (That a piece-safe deletion is never re-fetched was established
  directly against aria2 1.37 during the design probe; the loopback suite
  asserts the selection and volume state that the rule depends on.)
- Existing pause/resume/restart/app-restart RAM cases must still pass.

## 10. Out of scope

- Changing the batch planner's sizing, or the buffer picker. Stage 2 makes the
  window a soft bound; re-sizing it is a separate change.
- Sequential or rarest-first piece-priority tuning.
- Any change to PikPak upload, GCID, folder creation or reconciliation.
- BitTorrent v2 support.
