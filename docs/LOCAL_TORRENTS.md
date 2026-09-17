# Local torrent downloads

Open **Transfers → Torrents → New Torrent** from any drive. Paste a BitTorrent
v1/hybrid magnet link or open a `.torrent` file. **Load File List** fetches only
metadata. Then select files and choose **This Mac** or **PikPak · RAM only**.
A separate folder is created for each torrent.

The transfer card and magnet-loading dialog refresh connected peers, seeds and
download/upload speeds every second, including while the file list is loading.
An idle transfer shows `0 B/s`. Peer counts describe current connections to this
Mac (including seeds), not the total swarm; zero connected peers does not mean
the torrent has no peers elsewhere.
While a magnet's file list is loading, seeds are shown as **unknown** because
aria2 cannot classify connected peers as seeds until it has the torrent metadata.

A peer is counted only once it completes the BitTorrent handshake, read from
aria2's peer list rather than its `connections` total. `connections` also counts
sockets opened to peers that never answer, so a swarm this Mac cannot reach
would otherwise report a healthy peer count while nothing was connected. Any
excess shows separately as *(n trying)*. Because the peer list carries a piece
bitfield per peer it is read every few seconds rather than every second, but the
count still drops immediately when aria2 closes its sockets.

A download that makes no progress for 90 seconds states why on its card:
whether peers are connected but sending nothing, how many connection attempts
are unanswered, and whether incoming peers can reach this Mac.

## Peer discovery

Trackerless magnets bootstrap the DHT network through
`dht.transmissionbt.com:6881`, including when this Mac has no cached DHT nodes.

Torrents that name no tracker of their own also announce to a built-in list of
public trackers. DHT alone can take tens of minutes to find a first peer, and it
fails outright on networks that drop traffic to the public bootstrap nodes, so a
trackerless torrent would otherwise sit at zero bytes beside a live swarm. These
announces are **withheld** from torrents whose metadata sets the `private` flag,
and from metadata that cannot be parsed. A magnet is announced during its
file-list stage because a magnet cannot declare itself private before its
metadata arrives; once that metadata lands the torrent is re-added and the flag
is honoured.

The BitTorrent and DHT ports are mapped on the router with NAT-PMP (RFC 6886)
and kept alive while the engine runs. Stopping the engine or quitting releases
them, and the router expires them on its own if the app exits unexpectedly. The
pair is chosen once and reused across launches, recorded in `Engine/ports.json`.
Without a mapping only peers this Mac can dial are usable, and most of a typical
swarm sits behind NAT; the transfer card says so when a download stalls. Routers
offering only UPnP IGD, or no mapping at all, need the port forwarded by hand.

Magnets keep looking for peers until the file list arrives or you choose Pause
or Stop. If an attempt fails or the engine exits, it retries automatically after
15 seconds. Pause and Stop cancel pending retries.

PikPak Cloud Downloads also offers **Download to Mac** for a magnet rejected with
`task_sub_task_num_limit`. The link is carried to the local form; opening the
form does not contact peers. Choose **PikPak · RAM only** in that form to relay
selected files through this Mac. PikPak receives ordinary file uploads; its
cloud task file-count limit does not change.

## Download to PikPak using RAM (2.2.46)

1. Load the torrent file list and select the files you need.
2. Select **PikPak · RAM only**, choose a PikPak folder and a RAM buffer.
3. Click **Download to PikPak**. Each file is uploaded as soon as it finishes
   downloading, while the rest of the batch keeps arriving, so files appear in
   PikPak throughout a transfer rather than in one burst at the end.

Memory is returned as it is freed. Once a saved file's torrent pieces are no
longer needed by a file still being fetched, the file is deselected and removed
from the RAM volume; the volume itself is detached and reattached between
batches, which is what actually returns the memory to macOS. A file sharing a
piece with an unfinished neighbour is kept until that neighbour completes —
removing it early would only make the torrent engine fetch it a second time.
The card shows how many files have been freed this way.

The default buffer is up to 4 GiB. Choices start at 1 GiB and scale up to 75% of
physical RAM, leaving at least a quarter outside the buffer for macOS and other
apps. A 64 GiB Mac offers 1, 2, 4, 8, 16, 24, 32 and 48 GiB buffers. The picker,
batch planner and RAM volume use the same limit. One PikPak torrent holds a RAM
buffer at a time; other local-disk torrents can continue. The largest selected file, shared
boundary pieces and filesystem overhead must fit in that buffer. Oversized
files produce a clear selection error; there is no disk-cache fallback.

- **Pause** retains the buffer and suspends the current download or upload.
  **Resume** keeps partial torrent pieces and continues the upload worker.
- **Stop** releases RAM. It keeps completed PikPak files and the resume record.
- **Restart Download** discards unfinished RAM data and fetches it again. It
  checks saved cloud receipts and skips files already uploaded.
- **App restart:** the queue opens paused. Click Resume; existing RAM is
  reattached and torrent pieces are checked. After a Mac restart, lost RAM is
  recreated and unfinished files are downloaded again. An interrupted file's
  multipart upload may restart; completed cloud files are preserved.
- The task is bound to the original account, login method and destination.
  Select that account and login method before resuming. Uploads consume that
  login's upload allowance. User/Guest/Dynamic content mode does not change
  upload authentication. No PikPak credentials reach the BitTorrent engine.
- **Remove Torrent** stops the work, releases RAM and deletes its resume
  history. Completed PikPak files remain in their destination.

Payload is stored on a private, case-sensitive APFS `ram://` volume. Its
unmounted mountpoint is read-only, preventing accidental writes to the Mac's
disk if the volume disappears. Sparse files accommodate unselected boundary
pieces. Only torrent metadata, selections, account identity, file hashes and
cloud upload receipts are stored on disk. Upload credentials remain in memory.

Upload creation does not automatically retry a lost network response. Recovery
uses a pre-request item-ID snapshot and saved GCID to identify the accepted
file. If the service's response remains ambiguous, the task asks you to check
the destination before submitting another upload.

## Downloads to this Mac

- Shows completed bytes, download/upload speed, peers and seeds.
- Pause, resume and stop preserve partial files. Remove Torrent removes the
  history entry and stops its work; downloaded files remain on disk.
- Reopening the app restores a paused queue. Resume checks existing pieces
  before continuing. Reconnect the original external disk before resuming.
- Torrents use this Mac's network and disk, independently of PikPak login,
  User/Guest/Dynamic mode and transfer quotas. No PikPak credentials are sent
  to the torrent engine. Existing PikPak connection settings are unchanged.
- Three torrents may run concurrently. Total peer uploads are capped at
  1 MiB/s. Seeding stops after completion; BitTorrent still uploads pieces
  while a download is in progress.
- File lists need an available peer unless a `.torrent` file is supplied.
  Magnet metadata has no waiting timeout. Pure BitTorrent v2 magnets are not
  supported by the bundled aria2 version.
- Selecting files can require shared boundary pieces from adjacent files.
  Unselected files are removed at completion inside the torrent's own folder.
- Metadata is limited to 32 MiB and 200,000 listed files; queue storage is
  limited to 64 MiB. These are local memory/storage bounds.

## Engine and source

MyCloudDriver runs the unmodified [aria2 1.37.0](https://github.com/aria2/aria2/releases/tag/release-1.37.0)
as a separate process. Its JSON-RPC service listens only on loopback and uses a
fresh secret stored in a private configuration file. Queue and metadata files
are under `~/Library/Application Support/MyCloudDriver/LocalTorrents` (directory
mode 0700; state/config mode 0600). No external RPC listener is enabled.

Run `python3 scripts/prepare-torrent-engine.py` before the release build. It
verifies a pinned official source archive and builds for macOS 13+ using Apple
TLS and system libraries. The installed app has no Homebrew dependency.
`--verify-only` performs offline checks. `scripts/build-app.sh` packages and
signs the executable.

aria2 is GPL-2.0-or-later. Its license, complete corresponding source archive
and `BUILD.txt` reproduction instructions ship beside the executable in
`MyCloudDriver.app/Contents/Resources/TorrentEngine`. The native app communicates
with that separate executable through JSON-RPC. See the
[aria2 manual](https://aria2.github.io/manual/en/html/aria2c.html) for protocol
and file-selection behaviour.
