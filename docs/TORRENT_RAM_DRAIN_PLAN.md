# Torrent RAM Drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upload each torrent file to PikPak the moment it finishes downloading, and return its RAM as soon as it is safe to do so, instead of waiting for a whole 43 GB batch.

**Architecture:** aria2 already reports per-file `completedLength`. A new pure-logic file decides (a) when enough completed files have accumulated to be worth one uploader spawn, and (b) which committed files may be deselected and unlinked without aria2 rewriting them. The relay coordinator in `LocalTorrentRelay.swift` drives both while the download continues. Window boundaries recycle the RAM image rather than just emptying it.

**Tech Stack:** Swift 5 / SwiftUI (macOS 13+), aria2 1.37.0 over JSON-RPC, Rust helper `torrent-relay` (unchanged), `precondition`-based native test binary.

**Spec:** `docs/TORRENT_RAM_DRAIN_DESIGN.md`

## Global Constraints

- **Every new persisted field must be `Optional`.** Swift's synthesised `Codable` ignores property defaults and throws `keyNotFound` for a missing non-optional key; `LocalTorrentModel.swift:234-235` then sets `storageAvailable = false` and drops the entire queue. Follow the existing precedent on `LocalTorrentJob.attempted`.
- **Never rename or version-bump `queue-v1.json`** — `load()` rejects `version != 1`.
- **No task may call `stopRelay`, `restartRelay`, `ram.release` or `ram.clear` on a live user job as part of a migration.** A transfer is running against this code with ~4 GB of unrecoverable RAM payload.
- Piece-safety rule, verbatim from spec §4: a file is removable only when (1) it is committed, (2) every file overlapping its covering pieces is complete or already removed, and (3) it has been deselected in aria2.
- Delete order is always **deselect, then unlink**. Reversing it makes aria2 re-download the file (measured).
- Build/test commands, from `docs/TESTING.md`:
  - `./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests`
  - `/tmp/mycloud-torrent-tests`
  - `python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --ram`
  - `cargo test --lib torrent_relay`

---

## File Structure

| File | Responsibility |
|---|---|
| `macos/TorrentRelayDrain.swift` (new) | Pure logic: file layout, piece spans, removability, flush policy. No actor state, no I/O. |
| `macos/LocalTorrentEngine.swift` | Carry per-file `completedLength`; add `reselect` (changeOption without unpause). |
| `macos/LocalTorrentRelay.swift` | Drain coordinator: collect completions, flush uploads, apply removals. |
| `macos/TorrentRAMDisk.swift` | `recycle` = release + acquire, to reset the backing-store high-water mark. |
| `macos/TorrentRelayViews.swift` | Card shows saved/queued counts and live RAM held. |
| `scripts/LocalTorrentTests.swift` | Unit + fixture tests, including the compatibility guard. |
| `scripts/test-local-torrents.py` | Integration assertions against real peers. |

---

### Task 1: Queue decode compatibility guard

This task lands first and changes no production code. It is a characterisation test: it must pass **now**, and every later task must keep it passing. It is the only thing standing between a struct edit and the user losing a live 440 GB transfer.

**Files:**
- Modify: `scripts/LocalTorrentTests.swift` (add `queueCompatibility()`, register it in `main()`)

**Interfaces:**
- Consumes: nothing
- Produces: `LocalTorrentTests.queueCompatibility()` — later tasks re-run it unchanged

- [ ] **Step 1: Write the characterisation test**

Add to `scripts/LocalTorrentTests.swift`, before the closing brace of `extension LocalTorrentTests` (or as a new extension):

```swift
extension LocalTorrentTests {
    /// A queue written by the build that is running on the user's Mac today.
    /// Every key here exists in the live `queue-v1.json`; no new key may become
    /// mandatory, or the running 440 GB transfer is dropped on next launch.
    static let legacyQueueJSON = """
    {"version":1,"jobs":[{
      "id":"CC45EE42-78DD-4722-82F4-FC1824E79F11",
      "name":"Fixture torrent",
      "phase":"downloading",
      "files":[{"index":1,"path":"a/one.bin","length":1048576},
               {"index":2,"path":"a/two.bin","length":2097152}],
      "selected":[1,2],
      "pieceLength":33554432,
      "completed":0,
      "total":3145728,
      "downloadSpeed":0,
      "uploadSpeed":0,
      "peers":0,
      "seeders":0,
      "message":"Downloading batch 1 of 11 into RAM",
      "createdAt":779500000,
      "relay":{
        "identity":"11111111-2222-3333-4444-555555555555",
        "accountID":"acct-1",
        "credentialKind":"personal-access-token",
        "accountName":"USER_Apple",
        "parentID":"parent-1",
        "parentName":"My PikPak",
        "rootName":"Fixture-CC45EE42",
        "memoryBytes":51539607552,
        "batches":[[1],[2]],
        "batch":0,
        "uploaded":[],
        "batchReady":false,
        "batchDownloaded":3970000000,
        "batchTotal":43720000000,
        "currentBytes":0,
        "stage":""
      }
    }]}
    """

    @MainActor static func queueCompatibility() throws {
        let data = Data(legacyQueueJSON.utf8)
        let saved = try JSONDecoder().decode(LocalTorrentStore.Saved.self, from: data)
        precondition(saved.version == 1 && saved.jobs.count == 1, "legacy queue did not decode")
        let job = saved.jobs[0]
        precondition(job.name == "Fixture torrent")
        precondition(job.files.count == 2 && job.files[1].length == 2_097_152)
        precondition(job.selected == [1, 2])
        precondition(job.pieceLength == 33_554_432)
        precondition(job.attempted == nil, "absent optional keys must decode as nil")
        guard let relay = job.relay else { preconditionFailure("relay state was dropped") }
        precondition(relay.accountName == "USER_Apple")
        precondition(relay.memoryBytes == 51_539_607_552)
        precondition(relay.batches == [[1], [2]])
        precondition(relay.batch == 0 && relay.uploaded.isEmpty)
        precondition(relay.batchDownloaded == 3_970_000_000 && relay.batchTotal == 43_720_000_000)
        precondition(relay.volume == nil, "absent volume must decode as nil")

        // Re-encoding and decoding must also survive, so saving from the new
        // build and reloading it keeps every field.
        let round = try JSONDecoder().decode(LocalTorrentStore.Saved.self,
                                             from: JSONEncoder().encode(saved))
        precondition(round.jobs[0].relay?.batches == [[1], [2]])
        print("PASS queue compatibility: a queue saved by the shipping build still decodes, and round-trips")
    }
}
```

- [ ] **Step 2: Register it first in `main()`**

In `scripts/LocalTorrentTests.swift`, inside `main()`, add as the **first** call after the argument handling:

```swift
        try queueCompatibility()
        try sourceAndPersistence()
```

- [ ] **Step 3: Build and run — it must PASS**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests
```

Expected: `PASS queue compatibility: ...` then the existing suite's output. If it fails now, the fixture does not match the shipping struct — fix the fixture, never the struct.

- [ ] **Step 4: Prove the guard actually bites**

Temporarily add a non-optional field to `TorrentRelayState` in `macos/LocalTorrentRelay.swift`:

```swift
    var canaryField: Int = 0
```

Rebuild and run. Expected: the test **fails** with a `keyNotFound` decoding error. Then delete `canaryField` and rebuild to confirm it passes again. This is the only proof the guard works.

- [ ] **Step 5: Commit**

```bash
git add scripts/LocalTorrentTests.swift
git commit -m "test: guard queue-v1.json decoding against struct changes

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Per-file completedLength

**Files:**
- Modify: `macos/LocalTorrentEngine.swift:9-13` (`LocalTorrentWireFile`), `:41-45` (files parsing)
- Test: `scripts/LocalTorrentTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `LocalTorrentWireFile.completedLength: UInt64`

- [ ] **Step 1: Write the failing test**

```swift
extension LocalTorrentTests {
    @MainActor static func perFileProgress() throws {
        let status = LocalTorrentStatus([
            "status": "active", "totalLength": "3000", "completedLength": "1500",
            "files": [
                ["index": "1", "path": "/x/one.bin", "length": "1000", "completedLength": "1000"],
                ["index": "2", "path": "/x/two.bin", "length": "2000", "completedLength": "500"],
            ],
        ])
        precondition(status.files.count == 2)
        precondition(status.files[0].completedLength == 1000 && status.files[0].length == 1000)
        precondition(status.files[1].completedLength == 500)
        // A reply without the key must not drop the file.
        let sparse = LocalTorrentStatus([
            "status": "active",
            "files": [["index": "1", "path": "/x/one.bin", "length": "1000"]],
        ])
        precondition(sparse.files.count == 1 && sparse.files[0].completedLength == 0)
        print("PASS per-file progress: completedLength parsed, absent key defaults to zero")
    }
}
```

Register `try perFileProgress()` in `main()` after `try queueCompatibility()`.

- [ ] **Step 2: Run to verify it fails**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
```

Expected: compile error — `value of type 'LocalTorrentWireFile' has no member 'completedLength'`.

- [ ] **Step 3: Implement**

In `macos/LocalTorrentEngine.swift`, change `LocalTorrentWireFile`:

```swift
struct LocalTorrentWireFile {
    let index: Int
    let path: String
    let length: UInt64
    /// Bytes aria2 has verified for this file. `length` means the file is whole
    /// on the volume and may be handed to the uploader.
    let completedLength: UInt64
}
```

and the parser in `LocalTorrentStatus.init`:

```swift
        files = (value["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let index = Int(file["index"] as? String ?? ""), index > 0,
                  let path = file["path"] as? String, let length = UInt64(file["length"] as? String ?? "") else { return nil }
            return .init(index: index, path: path, length: length,
                         completedLength: UInt64(file["completedLength"] as? String ?? "") ?? 0)
        }
```

- [ ] **Step 4: Run to verify it passes**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests && /tmp/mycloud-torrent-tests
```

Expected: `PASS per-file progress: ...` and `PASS queue compatibility: ...` both present.

- [ ] **Step 5: Commit**

```bash
git add macos/LocalTorrentEngine.swift scripts/LocalTorrentTests.swift
git commit -m "feat: read per-file completedLength from aria2 status

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Drain logic (pure)

The heart of the change. All of it is pure functions over value types, so it is tested without aria2, without a RAM disk and without PikPak.

**Files:**
- Create: `macos/TorrentRelayDrain.swift`
- Test: `scripts/LocalTorrentTests.swift`

**Interfaces:**
- Consumes: `LocalTorrentFile` (index/path/length)
- Produces:
  - `TorrentRelayDrain.Layout(files:pieceLength:)`
  - `TorrentRelayDrain.removable(layout:complete:committed:removed:) -> [Int]`
  - `TorrentRelayDrain.shouldFlush(count:bytes:waiting:windowComplete:) -> Bool`

- [ ] **Step 1: Write the failing tests**

```swift
extension LocalTorrentTests {
    private static func drainFiles(_ lengths: [UInt64]) -> [LocalTorrentFile] {
        lengths.enumerated().map { .init(index: $0.offset + 1, path: "f\($0.offset).bin", length: $0.element) }
    }

    @MainActor static func drainLogic() throws {
        // Four 700-byte files against 1000-byte pieces: every piece is shared,
        // exactly the regime of the live torrent (22 MB files, 32 MiB pieces).
        let files = drainFiles([700, 700, 700, 700])
        let layout = TorrentRelayDrain.Layout(files: files, pieceLength: 1000)
        // file 1 = bytes 0..<700   -> piece 0        -> piece bytes 0..<1000
        // file 2 = bytes 700..<1400 -> pieces 0...1  -> piece bytes 0..<2000
        precondition(layout.pieceBytes(0) == 0..<1000)
        precondition(layout.pieceBytes(1) == 0..<2000)
        precondition(layout.touching(0..<1000) == 0..<2, "piece 0 carries files 1 and 2")

        // A lone committed file whose neighbour is still downloading must NOT
        // be removed: aria2 rewrites it when the shared piece lands. Measured.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [1],
                                                 committed: [1], removed: []) == [])
        // Once the sharing neighbour is complete too, file 1 may go.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [1, 2],
                                                 committed: [1], removed: []) == [1])
        // Committed but not complete is never removable.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [2],
                                                 committed: [1], removed: []) == [])
        // Already removed files are not offered twice, and count as settled.
        precondition(TorrentRelayDrain.removable(layout: layout, complete: [2, 3],
                                                 committed: [2], removed: [1]) == [2])

        // A file larger than a piece: only its own pieces matter.
        let big = TorrentRelayDrain.Layout(files: drainFiles([4000, 700]), pieceLength: 1000)
        precondition(big.pieceBytes(0) == 0..<4000, "file 1 owns pieces 0-3 outright")
        precondition(TorrentRelayDrain.removable(layout: big, complete: [1],
                                                 committed: [1], removed: []) == [1])

        // Zero-length files hold no bytes and never block a neighbour.
        let empty = TorrentRelayDrain.Layout(files: drainFiles([700, 0, 700]), pieceLength: 1000)
        precondition(TorrentRelayDrain.removable(layout: empty, complete: [1, 2, 3],
                                                 committed: [2], removed: []) == [2])

        // Flush policy.
        precondition(TorrentRelayDrain.shouldFlush(count: 0, bytes: 0, waiting: 9999, windowComplete: true) == false)
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 1, waiting: 0, windowComplete: true))
        precondition(TorrentRelayDrain.shouldFlush(count: 32, bytes: 1, waiting: 0, windowComplete: false))
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 256 * 1024 * 1024, waiting: 0, windowComplete: false))
        precondition(TorrentRelayDrain.shouldFlush(count: 1, bytes: 1, waiting: 180, windowComplete: false))
        precondition(TorrentRelayDrain.shouldFlush(count: 31, bytes: 1, waiting: 179, windowComplete: false) == false)
        print("PASS drain logic: piece spans, shared-piece safety and flush policy")
    }
}
```

Register `try drainLogic()` in `main()` after `try perFileProgress()`.

- [ ] **Step 2: Run to verify it fails**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
```

Expected: compile error — `cannot find 'TorrentRelayDrain' in scope`.

- [ ] **Step 3: Implement**

Create `macos/TorrentRelayDrain.swift`:

```swift
import Foundation

/// Which completed files may be uploaded, and which uploaded files may leave RAM.
///
/// Removal is the delicate half. A torrent's files are laid end to end, so one
/// piece often carries bytes for several files — in the torrents this feature
/// exists for, the median file is smaller than a single piece. aria2 writes a
/// piece to every file it overlaps, so deleting a file whose covering pieces
/// are still wanted by an incomplete neighbour merely recreates the file and
/// downloads it a second time. Only files whose every covering piece is fully
/// accounted for may go.
enum TorrentRelayDrain {
    /// Byte layout of the torrent, over every file it contains — selected or
    /// not, because unselected neighbours still share boundary pieces.
    struct Layout {
        let files: [LocalTorrentFile]
        let pieceLength: UInt64
        private let starts: [UInt64]
        private let ends: [UInt64]
        private let position: [Int: Int]

        init(files: [LocalTorrentFile], pieceLength: UInt64) {
            let ordered = files.sorted { $0.index < $1.index }
            var starts: [UInt64] = [], ends: [UInt64] = [], next: UInt64 = 0
            starts.reserveCapacity(ordered.count); ends.reserveCapacity(ordered.count)
            for file in ordered {
                starts.append(next)
                next = next.addingReportingOverflow(file.length).partialValue
                ends.append(next)
            }
            self.files = ordered
            self.starts = starts
            self.ends = ends
            self.pieceLength = max(1, pieceLength)
            self.position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.index, $0.offset) })
        }

        func slot(of index: Int) -> Int? { position[index] }

        /// The byte range of every piece that carries any of this file's bytes.
        /// A zero-length file occupies no piece and returns an empty range.
        func pieceBytes(_ slot: Int) -> Range<UInt64> {
            let start = starts[slot], end = ends[slot]
            guard end > start else { return start..<start }
            let first = start / pieceLength * pieceLength
            let last = ((end - 1) / pieceLength + 1) * pieceLength
            return first..<last
        }

        /// Slots of the files holding bytes inside `range`. Contiguous, because
        /// torrent files are concatenated, so this is two binary searches.
        func touching(_ range: Range<UInt64>) -> Range<Int> {
            guard !range.isEmpty else { return 0..<0 }
            var low = 0, high = files.count
            while low < high {
                let mid = (low + high) / 2
                if ends[mid] <= range.lowerBound { low = mid + 1 } else { high = mid }
            }
            let first = low
            low = 0; high = files.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < range.upperBound { low = mid + 1 } else { high = mid }
            }
            return first..<max(first, low)
        }
    }

    /// Files that may be deselected and unlinked, in index order.
    ///
    /// - `complete`: aria2 reports `completedLength == length`
    /// - `committed`: the relay helper wrote a cloud receipt
    /// - `removed`: already unlinked, so no further write is expected
    static func removable(layout: Layout, complete: Set<Int>, committed: Set<Int>, removed: Set<Int>) -> [Int] {
        var result: [Int] = []
        for (slot, file) in layout.files.enumerated() {
            guard committed.contains(file.index), !removed.contains(file.index),
                  complete.contains(file.index) else { continue }
            let span = layout.pieceBytes(slot)
            if span.isEmpty { result.append(file.index); continue }
            var safe = true
            for other in layout.touching(span) where other != slot {
                let index = layout.files[other].index
                if !complete.contains(index) && !removed.contains(index) { safe = false; break }
            }
            if safe { result.append(file.index) }
        }
        return result
    }

    static let flushFileLimit = 32
    static let flushByteLimit: UInt64 = 256 * 1024 * 1024
    static let flushWait: TimeInterval = 180

    /// Whether the queued completed files are worth one uploader spawn. The
    /// wait trigger is what keeps a slow swarm showing progress.
    static func shouldFlush(count: Int, bytes: UInt64, waiting: TimeInterval, windowComplete: Bool) -> Bool {
        guard count > 0 else { return false }
        if windowComplete { return true }
        return count >= flushFileLimit || bytes >= flushByteLimit || waiting >= flushWait
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests && /tmp/mycloud-torrent-tests
```

Expected: `PASS drain logic: ...`, and `PASS queue compatibility` still present.

- [ ] **Step 5: Commit**

```bash
git add macos/TorrentRelayDrain.swift scripts/LocalTorrentTests.swift
git commit -m "feat: add piece-safety and flush policy for relay draining

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Engine reselect

`begin` changes the selection **and** unpauses. Mid-flight deselection must not unpause a paused job, so it needs its own call.

**Files:**
- Modify: `macos/LocalTorrentEngine.swift` (protocol `LocalTorrentDriving`, `Aria2TorrentEngine`)
- Modify: `scripts/LocalTorrentTests.swift` (`TorrentFixtureEngine`)

**Interfaces:**
- Consumes: `LocalTorrentSource.selectionString`
- Produces: `func reselect(_ id: String, selection: [Int]) async throws`; `TorrentFixtureEngine.reselected: [(String, [Int])]`

- [ ] **Step 1: Write the failing test**

```swift
extension LocalTorrentTests {
    @MainActor static func engineReselect() async throws {
        let engine = TorrentFixtureEngine()
        try await engine.start()
        let gid = try await engine.addTorrent(Data("x".utf8), directory: URL(fileURLWithPath: "/tmp"), selection: [1, 2])
        try await engine.reselect(gid, selection: [2])
        precondition(engine.reselected.count == 1 && engine.reselected[0].1 == [2])
        // Reselect must not resume a paused download.
        precondition(engine.states[gid]?["status"] as? String == "paused",
                     "reselect must not unpause")
        print("PASS engine reselect: selection changes without unpausing")
    }
}
```

Register `try await engineReselect()` in `main()` after `try drainLogic()`.

- [ ] **Step 2: Run to verify it fails**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
```

Expected: compile error — no member `reselect`.

- [ ] **Step 3: Implement**

In `macos/LocalTorrentEngine.swift`, add to the `LocalTorrentDriving` protocol, directly after `begin`:

```swift
    func reselect(_ id: String, selection: [Int]) async throws
```

Add to `Aria2TorrentEngine`, directly after `begin`:

```swift
    /// Narrow a running download's file selection without resuming it.
    /// `begin` unpauses; a mid-flight deselection must not.
    func reselect(_ id: String, selection: [Int]) async throws {
        let indexes = try LocalTorrentSource.selectionString(selection)
        _ = try await call("changeOption", [id, ["select-file": indexes]])
    }
```

In `scripts/LocalTorrentTests.swift`, add to `TorrentFixtureEngine` — a stored property beside `begun`:

```swift
    var reselected: [(String, [Int])] = []
```

and a method beside `begin`:

```swift
    func reselect(_ id: String, selection: [Int]) async throws { reselected.append((id, selection)) }
```

- [ ] **Step 4: Run to verify it passes**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests && /tmp/mycloud-torrent-tests
```

Expected: `PASS engine reselect: ...`.

- [ ] **Step 5: Commit**

```bash
git add macos/LocalTorrentEngine.swift scripts/LocalTorrentTests.swift
git commit -m "feat: add aria2 reselect that narrows selection without unpausing

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Stage 1 — upload files as they complete

The change the running transfer needs. No deletion yet.

**Files:**
- Modify: `macos/LocalTorrentRelay.swift` (`TorrentRelayState`, `refreshRelay`, `runRelayUpload`, `advanceRelay`)
- Modify: `macos/LocalTorrentModel.swift` (drain bookkeeping properties)
- Test: `scripts/LocalTorrentTests.swift`

**Interfaces:**
- Consumes: `TorrentRelayDrain.shouldFlush`, `LocalTorrentWireFile.completedLength`
- Produces: `runRelayUpload(_:reconcile:generation:indexes:)`; `LocalTorrentModel.relayQueued: [UUID: Set<Int>]`, `relayQueuedSince: [UUID: Date]`, `relayFileCensusAt: [UUID: Date]`

- [ ] **Step 1: Write the failing test**

```swift
extension LocalTorrentTests {
    /// Files must reach PikPak while the batch is still downloading — the whole
    /// point of the change. Previously nothing uploaded until aria2 said
    /// "complete", which for the real torrent was 66 hours away.
    @MainActor static func streamingUploads() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(), ram = RelayFixtureRAM(), upload = RelayFixtureUpload()
        engine.files = [("a/one.bin", 1000), ("a/two.bin", 1000), ("a/three.bin", 1000)]
        let model = LocalTorrentModel(directory: root, engine: engine, ram: ram)
        let context = relayContext()
        model.relayContextProvider = { context }
        model.relayUploaderFactory = { upload }
        let id = try model.add(magnet: magnet)
        try await until("file list") { model.job(id)?.phase == .choosing }
        await model.downloadToPikPak(id, selected: [1, 2, 3], context: context, accountName: "Synthetic",
                                     parentID: "parent", parentName: "PikPak",
                                     memoryBytes: 256 * 1024 * 1024)
        try await until("downloading") { model.job(id)?.phase == .downloading }
        guard let gid = model.gids[id] else { preconditionFailure("no gid") }

        // aria2 reports file 1 whole while the torrent is still active.
        engine.states[gid]?["status"] = "active"
        engine.states[gid]?["completedLength"] = "1000"
        engine.setFileProgress(gid, [1: 1000, 2: 0, 3: 0])
        model.relayQueuedSince[id] = Date().addingTimeInterval(-TorrentRelayDrain.flushWait - 1)
        model.relayFileCensusAt[id] = nil
        await model.refreshRelay(id)

        try await until("file 1 saved before the batch finished", seconds: 10) {
            model.job(id)?.relay?.uploaded.contains(1) == true
        }
        precondition(engine.states[gid]?["status"] as? String != "complete",
                     "the batch must still be downloading when the first file is saved")
        precondition(upload.requested.contains { ($0["files"] as? [[String: Any]])?.count == 1 },
                     "only the completed file should have been sent")
        model.shutdown()
        print("PASS streaming uploads: a completed file reaches PikPak mid-batch")
    }
}
```

Add to `TorrentFixtureEngine` a helper so the test can drive per-file progress:

```swift
    /// Set per-file `completedLength` on a fixture download.
    func setFileProgress(_ id: String, _ progress: [Int: UInt64]) {
        guard var entries = states[id]?["files"] as? [[String: Any]] else { return }
        for position in entries.indices {
            let index = Int(entries[position]["index"] as? String ?? "") ?? 0
            entries[position]["completedLength"] = "\(progress[index] ?? 0)"
        }
        states[id]?["files"] = entries
    }
```

Also add `var requested: [[String: Any]] = []` to `RelayFixtureUpload` and append `request` at the top of its `run`. Register `try await streamingUploads()` in `main()`.

- [ ] **Step 2: Run to verify it fails**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
```

Expected: compile errors for `relayQueuedSince` / `relayFileCensusAt` / `setFileProgress` / `requested`, then once those exist, a timeout: `Test timed out: file 1 saved before the batch finished`.

- [ ] **Step 3: Implement**

In `macos/LocalTorrentModel.swift`, beside `relayLastProgress`:

```swift
    /// Completed files waiting for their uploader spawn, and when the oldest
    /// of them started waiting.
    var relayQueued: [UUID: Set<Int>] = [:]
    var relayQueuedSince: [UUID: Date] = [:]
    /// Per-file status is far heavier than the plain poll — a `files:true`
    /// reply for 14,623 files is megabytes — so it runs on the census cadence.
    var relayFileCensusAt: [UUID: Date] = [:]
    var relayFileCensusInterval: TimeInterval = 5
```

In `macos/LocalTorrentRelay.swift`, add to `TorrentRelayState` (all optional, per the global constraints):

```swift
    /// Files unlinked from the RAM volume. Distinct from `uploaded`: a file is
    /// uploaded first and only later becomes safe to delete. Optional so a
    /// queue written by an older build still decodes.
    var drained: [Int]?
```

Give `runRelayUpload` an explicit index set. Change its signature and the two lines that pick files:

```swift
    private func runRelayUpload(_ id: UUID, reconcile: Bool, generation: UUID, indexes: Set<Int>? = nil) async throws {
        try checkRelay(id, generation)
        guard let value = job(id), let state = value.relay else { return }
        let context = try relayContext(state), directory = try store.jobDirectory(id)
        let selected = indexes ?? Set(reconcile ? value.selected : state.batches[state.batch])
        let files = value.files.filter { selected.contains($0.index) && !state.uploaded.contains($0.index) }
```

In `refreshRelay`, after the existing `edit(id) { ... }` block that stores `batchDownloaded`, add the per-file census and flush:

```swift
            let due = relayFileCensusAt[id].map { Date().timeIntervalSince($0) >= relayFileCensusInterval } ?? true
            if due, status.state == "active" {
                relayFileCensusAt[id] = Date()
                let detail = try await engine.status(gid, files: true)
                guard job(id)?.phase == .downloading, gids[id] == gid, !busy.contains(id) else { return }
                guard let current = job(id)?.relay else { return }
                let done = Set(detail.files.filter { $0.completedLength >= $0.length }.map(\.index))
                let window = Set(current.batches[current.batch])
                let fresh = done.intersection(window).subtracting(current.uploaded)
                if !fresh.isEmpty {
                    if relayQueued[id, default: []].isEmpty { relayQueuedSince[id] = Date() }
                    relayQueued[id, default: []].formUnion(fresh)
                }
                let queued = relayQueued[id] ?? []
                let bytes = value.files.filter { queued.contains($0.index) }.reduce(UInt64(0)) { $0 + $1.length }
                let waiting = relayQueuedSince[id].map { Date().timeIntervalSince($0) } ?? 0
                if TorrentRelayDrain.shouldFlush(count: queued.count, bytes: bytes, waiting: waiting, windowComplete: false) {
                    relayQueued[id] = []; relayQueuedSince[id] = nil
                    try await flushRelayUploads(id, indexes: queued)
                    return
                }
            }
```

Add the flush helper beside `runRelayUpload`:

```swift
    /// Upload completed files while the rest of the window keeps downloading.
    /// The download is left running: BitTorrent and the PikPak upload share
    /// this Mac's link rather than taking turns.
    private func flushRelayUploads(_ id: UUID, indexes: Set<Int>) async throws {
        guard let generation = relayGenerations[id], relayUploaders[id] == nil, !indexes.isEmpty else { return }
        let phase = job(id)?.phase
        do {
            try await runRelayUpload(id, reconcile: false, generation: generation, indexes: indexes)
        } catch {
            // Keep the files queued; the next census retries them. A failed
            // upload must never silently drop a file from the window.
            relayQueued[id, default: []].formUnion(indexes)
            if relayQueuedSince[id] == nil { relayQueuedSince[id] = Date() }
            throw error
        }
        if let phase, job(id)?.phase == .uploading { edit(id) { $0.phase = phase } }
        relayFilesChanged?()
    }
```

In `advanceRelay`, the `state.batchReady` branch must no longer re-upload files that already committed. Replace its `runRelayUpload` call:

```swift
        if state.batchReady {
            busy.remove(id)
            let remaining = Set(state.batches[state.batch]).subtracting(state.uploaded)
            if !remaining.isEmpty { try await runRelayUpload(id, reconcile: false, generation: generation, indexes: remaining) }
            try checkRelay(id, generation)
```

- [ ] **Step 4: Run to verify it passes**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests && /tmp/mycloud-torrent-tests
```

Expected: `PASS streaming uploads: ...`, plus `PASS queue compatibility` and every pre-existing `PASS` line unchanged.

- [ ] **Step 5: Commit**

```bash
git add macos/LocalTorrentRelay.swift macos/LocalTorrentModel.swift scripts/LocalTorrentTests.swift
git commit -m "feat: upload torrent files to PikPak as each one finishes

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Stage 2 — reclaim RAM per drained run

**Files:**
- Modify: `macos/LocalTorrentRelay.swift` (`receiveRelay`, new `reclaimRelayRAM`)
- Test: `scripts/LocalTorrentTests.swift`

**Interfaces:**
- Consumes: `TorrentRelayDrain.removable`, `engine.reselect` (run-coalescing already happens inside `LocalTorrentSource.selectionString`)
- Produces: `TorrentRelayState.drained` populated; files unlinked from `volume.payload`

- [ ] **Step 1: Write the failing test**

```swift
extension LocalTorrentTests {
    @MainActor static func ramReclaim() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = TorrentFixtureEngine(), ram = RelayFixtureRAM(), upload = RelayFixtureUpload()
        // Three 700-byte files, 1000-byte pieces: every piece is shared.
        engine.files = [("a/one.bin", 700), ("a/two.bin", 700), ("a/three.bin", 700)]
        let model = LocalTorrentModel(directory: root, engine: engine, ram: ram)
        let context = relayContext()
        model.relayContextProvider = { context }; model.relayUploaderFactory = { upload }
        let id = try model.add(magnet: magnet)
        try await until("file list") { model.job(id)?.phase == .choosing }
        await model.downloadToPikPak(id, selected: [1, 2, 3], context: context, accountName: "Synthetic",
                                     parentID: "parent", parentName: "PikPak", memoryBytes: 256 * 1024 * 1024)
        try await until("downloading") { model.job(id)?.phase == .downloading }
        guard let gid = model.gids[id], let volume = model.job(id)?.relay?.volume else { preconditionFailure() }
        let payload = volume.payload.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        for name in ["one.bin", "two.bin", "three.bin"] {
            try Data(repeating: 7, count: 700).write(to: payload.appendingPathComponent(name))
        }

        // File 1 alone is committed and complete; file 2 shares its piece and
        // is still downloading, so nothing may be deleted yet.
        engine.setFileProgress(gid, [1: 700, 2: 0, 3: 0])
        await model.refreshRelay(id)
        model.receiveRelay(id, event: ["event": "committed", "index": 1])
        try await until("reclaim considered", seconds: 5) { !model.busy.contains(id) }
        precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent("one.bin").path),
                     "a file sharing a piece with an incomplete neighbour must stay")
        precondition(engine.reselected.isEmpty, "nothing should have been deselected yet")

        // Now file 2 completes too, so file 1's pieces are fully settled.
        engine.setFileProgress(gid, [1: 700, 2: 700, 3: 0])
        await model.refreshRelay(id)
        try await until("file 1 unlinked", seconds: 6) {
            !FileManager.default.fileExists(atPath: payload.appendingPathComponent("one.bin").path)
        }
        precondition(model.job(id)?.relay?.drained?.contains(1) == true)
        precondition(engine.reselected.last?.1.contains(1) == false,
                     "the drained file must be deselected before it is unlinked")
        precondition(FileManager.default.fileExists(atPath: payload.appendingPathComponent("two.bin").path),
                     "an uncommitted file must never be unlinked")
        model.shutdown()
        print("PASS RAM reclaim: shared-piece safety respected, drained file deselected then unlinked")
    }
}
```

Register `try await ramReclaim()` in `main()`. Make `receiveRelay` non-private so the test can drive a commit directly (change `private func receiveRelay` to `func receiveRelay`).

- [ ] **Step 2: Run to verify it fails**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
```

Expected: timeout — `Test timed out: file 1 unlinked`.

- [ ] **Step 3: Implement**

In `macos/LocalTorrentRelay.swift`, at the end of `receiveRelay`, replace the trailing `if kind == "committed" { saveOrReport() }` with:

```swift
        if kind == "committed" {
            saveOrReport()
            Task { await reclaimRelayRAM(id) }
        }
```

Add the reclaim routine beside `flushRelayUploads`:

```swift
    /// Deselect and unlink committed files whose pieces no longer serve any
    /// file still being downloaded, returning their RAM to the volume.
    ///
    /// Order matters: aria2 rewrites a file that is still selected, so the
    /// selection is narrowed first and the unlink follows. A file whose pieces
    /// are shared with an unfinished neighbour is left alone — deleting it
    /// would simply fetch it a second time.
    func reclaimRelayRAM(_ id: UUID) async {
        guard !closed, !busy.contains(id), let value = job(id), let state = value.relay,
              let volume = state.volume, let gid = gids[id], let pieceLength = value.pieceLength,
              pieceLength > 0, engine.running else { return }
        let window = Set(state.batches[state.batch])
        let removed = Set(state.drained ?? [])
        let layout = TorrentRelayDrain.Layout(files: value.files, pieceLength: pieceLength)
        do {
            let detail = try await engine.status(gid, files: true)
            guard job(id)?.relay?.volume == volume, gids[id] == gid, !busy.contains(id) else { return }
            let complete = Set(detail.files.filter { $0.completedLength >= $0.length }.map(\.index))
            let ready = TorrentRelayDrain.removable(layout: layout, complete: complete,
                                                    committed: state.uploaded, removed: removed)
                .filter { window.contains($0) }
            guard !ready.isEmpty else { return }
            let keep = window.subtracting(removed).subtracting(ready).sorted()
            // Never leave aria2 with an empty selection; the window boundary
            // tears the job down instead.
            if !keep.isEmpty { try await engine.reselect(gid, selection: keep) }
            var unlinked: [Int] = []
            for index in ready {
                guard let file = value.files.first(where: { $0.index == index }) else { continue }
                let path = volume.payload.appendingPathComponent(file.path)
                do {
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                    unlinked.append(index)
                } catch {
                    // Leave it for the window boundary rather than failing the
                    // transfer; the bytes are already safe in PikPak.
                    continue
                }
            }
            guard !unlinked.isEmpty else { return }
            edit(id) { $0.relay?.drained = ($0.relay?.drained ?? []).appendingUnique(unlinked) }
            saveOrReport()
        } catch {
            // Reclaim is opportunistic. A failure costs memory, never data.
            return
        }
    }
```

Add the small helper at the bottom of `macos/TorrentRelayDrain.swift`:

```swift
extension Array where Element == Int {
    /// Union preserving ascending order, for the persisted drained list.
    func appendingUnique(_ values: [Int]) -> [Int] { Array(Set(self).union(values)).sorted() }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests && /tmp/mycloud-torrent-tests
```

Expected: `PASS RAM reclaim: ...` plus every earlier `PASS` line.

- [ ] **Step 5: Commit**

```bash
git add macos/LocalTorrentRelay.swift macos/TorrentRelayDrain.swift scripts/LocalTorrentTests.swift
git commit -m "feat: return RAM as uploaded torrent files become piece-safe

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Stage 3 — recycle the volume at window boundaries

Measured: deleting inside the image returns only the page-cache copy; the ramdisk backing store plateaus at the high-water mark and is released only by `hdiutil detach`. `clear` therefore leaves ~43 GB claimed for the rest of the job.

**Files:**
- Modify: `macos/TorrentRAMDisk.swift` (protocol `TorrentRAMDriving` + extension default)
- Modify: `macos/LocalTorrentRelay.swift:195,201` (the two `ram.clear` calls in `advanceRelay`)
- Test: `scripts/LocalTorrentTests.swift`

**Interfaces:**
- Consumes: `acquire`, `release`
- Produces: `func recycle(_ volume:id:bytes:directory:) async throws -> TorrentRAMVolume`

- [ ] **Step 1: Write the failing test**

```swift
extension LocalTorrentTests {
    @MainActor static func ramRecycle() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let ram = RelayFixtureRAM(), id = UUID()
        let first = try await ram.acquire(id: id, bytes: 256 * 1024 * 1024, directory: root)
        let second = try await ram.recycle(first, id: id, bytes: 256 * 1024 * 1024, directory: root)
        precondition(ram.released.contains(first.uuid), "recycle must detach the old image")
        precondition(ram.volumes.count == 1, "exactly one image stays attached")
        precondition(second.owner == id && second.bytes == 256 * 1024 * 1024)
        print("PASS RAM recycle: the window boundary detaches and reattaches, resetting the high-water mark")
    }
}
```

Add `var released: [String] = []` to `RelayFixtureRAM` and append `volume.uuid` in its `release`. Register `try await ramRecycle()` in `main()`.

- [ ] **Step 2: Run to verify it fails**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
```

Expected: compile error — no member `recycle`.

- [ ] **Step 3: Implement**

In `macos/TorrentRAMDisk.swift`, add to the protocol:

```swift
@MainActor protocol TorrentRAMDriving {
    func acquire(id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume
    func validate(_ volume: TorrentRAMVolume) async throws
    func clear(_ volume: TorrentRAMVolume) async throws
    func release(_ volume: TorrentRAMVolume) async throws
    func recycle(_ volume: TorrentRAMVolume, id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume
}

extension TorrentRAMDriving {
    /// Detach and reattach rather than emptying in place.
    ///
    /// A `ram://` image allocates lazily but never gives blocks back: deleting
    /// files inside it returns only the page-cache copy, while the backing
    /// store stays at the high-water mark of bytes ever resident until the
    /// image is detached. Emptying a 43 GB window in place therefore leaves
    /// 43 GB claimed for every window that follows.
    func recycle(_ volume: TorrentRAMVolume, id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume {
        try await release(volume)
        return try await acquire(id: id, bytes: bytes, directory: directory)
    }
}
```

In `macos/LocalTorrentRelay.swift`, replace the two `ram.clear(volume)` calls inside `advanceRelay`. The first, in the `advancedBatch` branch:

```swift
        if advancedBatch { volume = try await ram.recycle(volume, id: id, bytes: state.memoryBytes, directory: store.jobDirectory(id)); state.volume = volume }
```

(change `let volume` to `var volume` on the `ram.acquire` line above it), and the second, in the `state.batchReady` branch:

```swift
            let next = try await ram.recycle(volume, id: id, bytes: state.memoryBytes, directory: store.jobDirectory(id))
            edit(id) { $0.relay?.volume = next; $0.relay?.batchReady = false; $0.relay?.batch += 1
                       $0.relay?.batchDownloaded = 0; $0.relay?.currentBytes = 0; $0.relay?.drained = [] }
```

Leave `ram.clear` in place — `stopRelay` and the pause paths still use it.

- [ ] **Step 4: Run to verify it passes**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests && /tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests --ram-volume
```

Expected: `PASS RAM recycle: ...` and the real-RAM-disk case still passing.

- [ ] **Step 5: Commit**

```bash
git add macos/TorrentRAMDisk.swift macos/LocalTorrentRelay.swift scripts/LocalTorrentTests.swift
git commit -m "fix: detach and reattach the RAM image between windows

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Card, integration test and docs

**Files:**
- Modify: `macos/TorrentRelayViews.swift:60-88` (`TorrentRelayProgress`)
- Modify: `scripts/test-local-torrents.py`
- Modify: `docs/LOCAL_TORRENTS.md`, `docs/TESTING.md`

- [ ] **Step 1: Show drained state on the card**

In `macos/TorrentRelayViews.swift`, inside the `if relay.volume != nil` block, replace the batch line's `Text("\(LocalTorrentFormat.bytes(relay.batchDownloaded)) / \(LocalTorrentFormat.bytes(relay.batchTotal))")` group by adding, after the peers `Text`:

```swift
                        if let drained = relay.drained, !drained.isEmpty {
                            Text("\(drained.count) freed from RAM")
                                .help("Files already saved to PikPak whose memory has been returned. They are not downloaded again.")
                        }
```

- [ ] **Step 2: Assert streaming in the loopback integration test**

In `scripts/LocalTorrentTests.swift`, in `actualRelay`, replace the single wait for completion with a mid-flight assertion. After the existing `try await until("real RAM torrent pieces", seconds: 50) { ... }` line, add:

```swift
            try await until("a file is saved before the batch finishes", seconds: 90) {
                (first.job(id)?.relay?.uploaded.isEmpty == false) || first.job(id)?.phase == .failed
            }
            precondition(first.job(id)?.phase != .failed, first.job(id)?.message ?? "relay failed")
```

- [ ] **Step 3: Run the full local + loopback suites**

```bash
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests
/tmp/mycloud-torrent-tests --ram-volume
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-tests --ram
cargo test --lib torrent_relay
```

Expected: every suite passes. The `--ram` run must print the new mid-flight assertion's progress before the completion line.

- [ ] **Step 4: Update the docs**

In `docs/LOCAL_TORRENTS.md`, replace the third bullet of "Download to PikPak using RAM" with:

```markdown
3. Click **Download to PikPak**. Each file is uploaded as soon as it finishes
   downloading, while the rest of the batch continues. Memory is returned once
   a saved file's torrent pieces are no longer needed by a file still being
   fetched, and the RAM volume is reattached between batches.
```

In `docs/TESTING.md`, under "RAM torrent uploads", add:

```markdown
The native suite covers the queue-decode compatibility guard, per-file
progress parsing, piece-safety drain logic, `reselect`, streaming uploads,
RAM reclaim and volume recycling. `queueCompatibility` must pass before any
change to `LocalTorrentJob` or `TorrentRelayState` ships: it decodes a queue
written by the shipping build, and a new non-optional field breaks it.
```

- [ ] **Step 5: Commit**

```bash
git add macos/TorrentRelayViews.swift scripts/LocalTorrentTests.swift docs/LOCAL_TORRENTS.md docs/TESTING.md
git commit -m "feat: surface drained files, assert streaming uploads, update docs

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Deployment for the live transfer

The user has a 440 GB transfer mid-flight with ~4 GB of unrecoverable RAM payload. After Task 5 (or later) is built:

1. Quit MyCloudDriver normally — ⌘Q or Quit. **Never press Stop or Restart Download**; those are the only paths that call `ram.release` and discard the payload.
2. Install the new build over the old one. Application Support is untouched.
3. Relaunch and press **Resume** on the torrent.
4. `acquire()` revalidates and reattaches the existing ramdisk; aria2 re-checks the pieces already in it; per-file uploads begin within one census interval.

Tasks 1–6 need no re-plan of the existing 11×43.72 GB batch layout. Task 7 takes effect at the next window boundary.
