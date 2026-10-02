# Sliding RAM window for PikPak torrents

Implemented in `LocalTorrentRelay.swift` and `TorrentRelayDrain.swift`.

The scheduler admits files in torrent order using two limits: the full lengths
of all resident files plus shared-piece/filesystem overhead must fit within 85%
of the RAM budget, and actual free space must cover every unwritten reserved
byte plus a 16 MiB safety margin. Partially downloaded sparse files still reserve
their unfinished bytes. Adjacent files share boundary overhead, so a large
manifest of small files does not waste the buffer.

After **Switch to Storage**, the RAM budget and its 85% ceiling no longer apply.
The same admission calculation reserves unfinished bytes and overhead against
the smaller of live free space and remaining configured storage allowance,
retaining the 16 MiB safety margin. The automatic total allowance is allocated
torrent bytes plus drive free bytes minus 100 GB. A custom total disk allowance
can be changed while downloading. Space
and transfer-owned allocated bytes are remeasured each census and after restart;
the card shows usage and the current limit. Uploaded files stay available for
sharing until room is needed for incomplete or waiting files. Lowering the
limit immediately shrinks an overcommitted selection to the partial file nearest
completion and flushes finished files to the uploader. Partial files are retained,
so the limit can be exceeded temporarily while they finish. No new empty
`select-file` filter is issued. The optional `storageLimitBytes` and
`keepUploadedFiles` fields preserve old queues; their defaults enable automatic
capacity and retention. Immediate cleanup remains selectable.

Every file census collects verified files for upload and reclaims committed
files whose shared pieces are safe. Waiting files flush immediately when
admission is blocked, when every admitted file is complete, or at the existing
file-count, byte-count, fill-pressure and waiting-time thresholds. Uploads run
independently of the poller, so telemetry and admission continue while PikPak is
receiving data.

A saved file can be reclaimed at the frontier even if the next unadmitted file
shares a piece. Its boundary may be downloaded again when that neighbour is
admitted. Recreated boundary stubs and unselected fragments are also reclaimed.
An unfinished *admitted* neighbour continues to pin its shared bytes.

The volume is never cleared or detached during a refill. There is one torrent
GID until completion, Stop or recovery. **Stock aria2 1.37.0 does not change an
active `select-file` filter without reopening the transfer.** The implementation
waits for a pause acknowledgement, which closes file descriptors, before
unlinking saved files and changing the selection. It then resumes the same GID;
peers may reconnect; unchanged files reuse their verified checkpoint. This corrects the earlier
design's assumption that selection growth could preserve every peer connection.
Recreated shared-piece stubs do not trigger another pause when the selection is
unchanged. Small completed uploads also do not reset a productive window with
spare RAM or storage. Refill is triggered by low remaining work (25% of the buffer), a
useful amount of reclaimable data (12.5%), or space pressure (75% occupancy), and
always when admitted work finishes. Uploads keep running while reclamation is
deferred. The final selection stays intact while there is still download work
and no space pressure. Storage uses its measured available space plus allocated
payload for these thresholds; it must not bypass coalescing after each receipt.
Neither a pending nor an active hash check may trigger a file census, cleanup
or reselection. The file census also checks for hashing to close the race with
the lightweight status poll. `verifiedLength` being present at zero counts as
an active check, as specified by the [aria2 RPC contract](https://aria2.github.io/manual/en/html/aria2c.html#aria2.tellStatus).
The relay keeps the GID alive when its admitted selection completes, and removes
it immediately once all chosen files are confirmed saved to PikPak.

Saved batch fields remain decodable for migration. Optional `selection`,
`downloadedBytes`, `bufferUsed` and `bufferAvailable` fields describe the rolling transfer. Legacy
queues retain their current partial files; cloud receipts remain authoritative
for which files must never be uploaded twice. Restored paused transfers resume
once per app launch and only under their original account. Stop remains stopped.

The card presents overall download and saved-to-PikPak percentages separately,
with a download ETA from the current rate, occupancy and transfer speeds. There
is no batch counter or freed-from-RAM counter. An empty peer list stays available
and retains the user's disclosure state.

Verification uses synthetic native fixtures and generated loopback torrents:

```sh
./scripts/build-native-test.sh scripts/LocalTorrentTests.swift /tmp/mycloud-torrent-sliding-tests
/tmp/mycloud-torrent-sliding-tests
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-sliding-tests --grow
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-sliding-tests --ram
python3 scripts/test-local-torrents.py /tmp/mycloud-torrent-sliding-tests --rolling
```

The rolling fixture transfers three generated 100 MiB files through a 256 MiB
RAM volume and checks SHA-256 at a synthetic cloud sink. It also pauses,
recreates the model, automatically resumes, and asserts the torrent GID remains
stable across refills. No fixture inspects the user's torrent queue or payloads,
uses a public swarm, or uploads to a real PikPak account.
