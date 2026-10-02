# Local torrent downloads

Open **Transfers → Torrents → New Torrent** from any drive. Paste a BitTorrent
v1/hybrid magnet link or open a `.torrent` file. **Load File List** fetches only
metadata. Then select files and choose **This Mac** or **PikPak · RAM only**.
A separate folder is created for each torrent.

The transfer card and magnet-loading dialog refresh connected peers, seeds and
download/upload speeds every ten seconds, including while the file list is loading.
An idle transfer shows `0 B/s`. Peer counts describe current connections to this
Mac (including seeds), not the total swarm; zero connected peers does not mean
the torrent has no peers elsewhere.
While a magnet's file list is loading, seeds are shown as **unknown** because
the engine cannot classify connected peers as seeds until it has the torrent metadata.

A peer is counted only once it completes the BitTorrent handshake. Pending
connections appear separately as *(n trying)*. The expanded peer list shows each
connection's TCP or µTP transport and actual payload rates; a connected peer can
still choke us or have no wanted pieces. Peer details normally refresh every 30 seconds.

Detailed file progress and storage usage also refresh every 30 seconds, so large
torrents do not repeatedly scan thousands of files just to update the display.
Transfers continue between refreshes; a newly completed file may wait until the
next file check before its cloud upload starts. Restored sign-in and due upload
retries bypass this delay. A detailed status response reuses
one freshly validated file-progress snapshot for both its summary and file rows.
Storage usage is measured again after cleanup, but an unchanged refill pass reuses
its initial measurement. These snapshots and status JSON remain in memory.

Periodic resume checkpoints run every three minutes. Pause, cleanup and normal
app shutdown still save immediately. After a crash, a less recent checkpoint may
require rechecking more downloaded data; payload files are kept. The engine's
idle maintenance loop wakes twice per second and accepts status/control requests
immediately when they arrive.

Version 2.3 uses libtorrent 2.0.14 with both TCP and µTP, encrypted peer
handshakes, DHT, tracker discovery and peer exchange. µTP adds a route to peers
that the earlier TCP-only engine could not use. It cannot guarantee a speed:
remote peers and the current network route still control availability.

Torrent padding entries align pieces and are not user files. Explicit padding
attributes and legacy BitComet padding are excluded from file selection, cloud
uploads, file counts and payload totals. Their lengths stay in the piece layout.
Existing transfers adopt these flags from the engine without deleting any old
cloud receipts. A short or absent padding file does not mean payload is corrupt.
Legacy local padding stubs are released through the live engine even when the
storage limit has room. This preserves the verified-piece resume cache. Old
padding uploads are automatically moved to PikPak Trash using the original
account/job binding, upload IDs, exact paths, lengths and saved cloud hashes.
Cleanup reads metadata only, preserves receipts, and never searches the drive
by filename. Missing replies and app restarts reconcile the same IDs; temporary
failures retry with a capped delay without stopping torrent downloads. Pause
and Stop also hold cleanup. Changed or ambiguous cloud files are kept for a
later check. Cleanup does not empty Trash or remove real files or folders.
PikPak processes bulk Trash requests asynchronously. Receipts stay pending
until a fresh cloud listing confirms removal; an interrupted or stalled request
is checked again and can be resent after five minutes without creating a new file.

Public torrents remember up to 64 peers that completed a handshake, preferring
peers that transferred data and seeds. These numeric endpoints live in the
private `Engine/Peers` cache, expire after 24 hours, and are offered to the
engine when the torrent starts or resumes, then every five minutes while it
runs. libtorrent stops dialing a peer after three failed attempts and revives
it only when a tracker lists it again, so without the repeat a seeder that went
offline, and is listed by no tracker, would not be dialed again until the next
start. The cache is separate from the saved queue and
is limited to 128 torrents. Pending connections, virtual DNS addresses, local
addresses, and unknown incoming ports are excluded. Private torrents and
unverified magnet metadata do not use this cache. Cached peers still have to
connect and complete a new handshake before they count as connected.

The engine's authenticated `aria2.addPeers` extension accepts at most 64 numeric
IP/port pairs for an active torrent. It validates the entire batch before adding
peers and leaves duplicate handling, connection limits and routing to the usual
peer scheduler. Each hint earns a peer that libtorrent had given up on the same
single retry a tracker listing would; a connected peer is unaffected. Invalid or
missing caches do not interrupt the download.

A download that makes no progress for 90 seconds states why on its card:
whether peers are connected but sending nothing, how many connection attempts
are unanswered, and what is known about incoming port mappings. A successful
mapping alone does not verify reachability from outside the network. Virtual
DNS addresses in `198.18.0.0/15` identify a proxy; they do not prove traffic is
blocked, because capable tunnels forward both TCP and UDP through them.

Expand **Connection details** on a torrent card to see discovered peer addresses,
responding/failing trackers, DHT routing nodes and the most recent connection
failure. These counters refresh at most once every 30 seconds. Discovered
addresses and pending attempts do not count as connected peers until their
BitTorrent handshakes finish. The diagnostic request reads network state only;
it does not inspect downloaded files or report torrent names, hashes, file paths
or tracker passkeys.

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

The BitTorrent and DHT ports are mapped on the router with NAT-PMP (RFC 6886),
with UPnP IGD as a fallback, and kept alive while the engine runs. Stopping the engine or quitting releases
them, and the router expires them on its own if the app exits unexpectedly. The
listening port is reused across launches, recorded in `Engine/ports.json`.
TCP uses that port for incoming peers; UDP shares it between µTP and DHT.
Outgoing peer connections can work without an incoming mapping. A LAN router
mapping may not apply to a VPN's exit address, and neither the absence nor the
presence of a mapping alone establishes which remote peers are reachable.

Magnets keep looking for peers until the file list arrives or you choose Pause
or Stop. If an attempt fails or the engine exits, it retries automatically after
15 seconds. Pause and Stop cancel pending retries.

Payload downloads also keep looking when a swarm goes quiet. The engine's
`bt-stop-timeout` is explicitly zero, so a zero-byte rate does not stop a torrent.
Lost or timed-out local status connections are retried at the normal poll
cadence while the engine remains alive, without pausing or reselecting its
torrent. After five missing replies, stale peer details disappear; the live
counts return automatically when status is available again. Actual engine
errors still use the ordinary error path, and explicit Pause/Stop are respected.
Remote peers can disconnect or withhold pieces; keeping the engine active lets
it reconnect and continue as soon as a usable peer is available.

PikPak Cloud Downloads also offers **Download to Mac** for a magnet rejected with
`task_sub_task_num_limit`. The link is carried to the local form; opening the
form does not contact peers. Choose **PikPak · RAM only** in that form to relay
selected files through this Mac. PikPak receives ordinary file uploads; its
cloud task file-count limit does not change.

## Download to PikPak using RAM (2.2.46)

1. Load the torrent file list and select the files you need.
2. Select **PikPak · RAM only**, choose a PikPak folder and a RAM buffer.
3. Click **Download to PikPak**. A sliding window admits files as space becomes
   available. Finished files upload while other admitted files keep arriving;
   once PikPak confirms a file, its RAM can be reused for the next file.

The window reserves each admitted file's full size, including its unfinished
bytes and shared torrent pieces. Admission also checks the volume's actual free
space, so sparse partial files cannot overfill the buffer. A slow PikPak upload
naturally holds back new downloads. Completed files flush immediately when more
work is waiting for space, without waiting for a fixed batch to finish.

Files sharing pieces with an unfinished admitted neighbour remain in RAM. An
unadmitted neighbour cannot pin a saved file forever: the shared boundary may
be downloaded again when that neighbour enters the window. Unselected boundary
fragments are reclaimed as well. The same RAM volume and torrent ID last for
the whole transfer. The libtorrent backend updates file priorities live. Partial
pieces are retained, and a selection change does not require a pause/recheck.
Explicit app pause, buffer relocation and exhausted windows can still close peers.

To keep peer connections stable, the relay does not reopen an unchanged window
just to remove shared-piece stubs. Uploaded files may stay in RAM temporarily
while there is spare capacity and plenty of admitted work. It advances when
unfinished admitted bytes fall to a quarter of the buffer, reclaimable files
reach an eighth, or actual buffer occupancy reaches 75%. A finished window
advances immediately. The final window stays connected while its remaining
files download unless RAM is under pressure. Uploading continues throughout;
these are memory/work thresholds, not fixed batches.

The card shows separate download and saved-to-PikPak percentages, downloaded
bytes, current rates, buffer occupancy, and a download ETA based on the current
rate. ETA is unavailable while paused or waiting for traffic. The peer section
keeps its expanded/collapsed state even when there are no connected peers.
**Downloaded overall** includes data already uploaded and released from the
buffer; **currently in RAM** shows the buffer's current occupancy. The **total**
is the selected torrent size, not an allocation on this Mac's storage.

**Disk space used** and **Saved to PikPak** overlap. Disk usage includes partial
files, torrent bookkeeping and uploaded copies retained for sharing or whose
shared pieces are still needed by unfinished files. **Downloaded overall** counts selected bytes once;
subtracting **Saved to PikPak** gives the displayed downloaded bytes not yet
saved to PikPak, including incomplete files. Storage cleanup runs on the file
census (normally every 30 seconds): durably confirmed uploads are retained
within the storage limit and reclaimed when space is needed, once their admitted
shared-piece neighbours are complete. **Keep Uploaded Files for Sharing** can be
turned off for immediate cleanup. Piece verification defers cleanup until it finishes. The bundled
engine closes and unlinks the eligible files without pausing the torrent,
changing its selection, or disconnecting its peers. Released pieces are no
longer advertised or served. A failed cleanup RPC is retried on a later census
while downloading continues. Admitting new files can still require the normal
selection refill described above; final completion clears remaining payload.

The default buffer is up to 4 GiB. Choices start at 1 GiB and scale up to 75% of
physical RAM, leaving at least a quarter outside the buffer for macOS and other
apps. A 64 GiB Mac offers 1, 2, 4, 8, 16, 24, 32 and 48 GiB buffers. The picker,
window scheduler and RAM volume use the same limit. One PikPak torrent holds a RAM
buffer at a time; other local-disk torrents can continue. The largest selected file, shared
boundary pieces and filesystem overhead must fit in that buffer. Oversized
files produce a clear selection error; there is no disk-cache fallback.

- **Pause** retains the buffer and suspends the current download or upload.
  **Resume** keeps partial torrent pieces and continues the upload worker.
- **Stop** releases RAM. It keeps completed PikPak files and the resume record.
- **Restart Download** discards unfinished RAM data and fetches it again. It
  checks saved cloud receipts and skips files already uploaded.
- **App restart:** paused or interrupted downloads automatically continue from
  saved progress even if PikPak is unavailable. Existing RAM
  is reused; unchanged files reuse verified resume data. After a Mac restart, lost
  RAM is recreated and unfinished files are downloaded again. An interrupted
  file's multipart upload may restart; completed cloud files are preserved.
  Pressing Pause again holds the transfer for the current app session. Stopped,
  failed, completed, and file-selection-only entries do not start automatically.
- The task is bound to the original PikPak **account** and destination. Select
  that account to resume cloud uploads; downloading can continue without it.
  The login method may change mid-transfer —
  switch between normal sign-in and a Personal Access Token and the transfer
  continues under whichever is active, which is how an upload moves off a
  token's 25% allowance onto the full account allowance. Saved cloud receipts
  stay valid across the switch, so nothing is uploaded twice. The account
  itself is checked here and verified again against the server before any
  cloud change. Uploads consume the active login's allowance.
  User/Guest/Dynamic content mode does not change upload authentication. No
  PikPak credentials reach the BitTorrent engine.
  Use the **Token login / Normal login** menu on the torrent card to switch the
  original account's upload connection. It selects the saved login or opens the
  existing sign-in flow; both login methods remain saved. An in-flight upload
  helper is stopped and its receipts checked using the new login. The torrent's
  peer session, download destination, file selection and any piece verification
  stay intact. The chosen login also applies to this workspace's other PikPak
  requests.
- **PikPak connection or sign-in loss** holds only cloud uploads. The torrent
  keeps downloading into its chosen RAM or storage buffer while space is
  available. Files without a confirmed upload remain local. Connection failures
  retry automatically, starting after 30 seconds and backing off to 5 minutes;
  restoring the original account makes uploads eligible immediately. Retries
  reconcile saved receipts before uploading again. A full buffer waits for
  uploads to free space. Explicit Pause and Stop still hold the whole transfer.
- **Remove Torrent** stops the work, releases RAM and deletes its resume
  history. Completed PikPak files remain in their destination.

Payload is stored on a private, case-sensitive APFS `ram://` volume. Its
unmounted mountpoint is read-only, preventing accidental writes to the Mac's
disk if the volume disappears. Sparse files accommodate unselected boundary
pieces. Only torrent metadata, selections, account identity, file hashes and
cloud upload receipts are stored on disk. Upload credentials remain in memory.
Before starting or resuming a relay, the app verifies the RAM volume and the
engine's actual file paths, including unselected boundary files. A stale engine
handle pointing at a disk folder is paused and rejected. A missing RAM mount or
a payload folder redirected outside that volume is rejected as well.

Upload creation does not blindly repeat a lost network response. Recovery
uses a pre-request item-ID snapshot and saved GCID to identify the accepted
file. If the service's response remains ambiguous, the task asks you to check
the destination before submitting another upload.

## Switch a PikPak torrent from RAM to storage

In **Transfers → Torrents**, open a RAM transfer's **…** menu and choose
**Switch to Storage…**. Choose a writable folder on this Mac or a connected
disk. The app creates a private staging folder inside it, briefly pauses the
torrent, and copies the existing partial files and torrent resume data. Once
the storage copy and its location are saved, it releases RAM. An active
transfer continues automatically; a paused transfer stays paused.

The transfer keeps its selected files, PikPak account, cloud destination and
upload receipts. Files still upload automatically to PikPak. Confirmed files
stay available for sharing with peers while there is room. Cleanup does not reopen the
torrent or disconnect its peers. Final completion clears the remaining staging data.

**… → Storage Limit…** changes the total disk allowance during a download.
The default is **Automatic — leave 100 GB free on the drive**: current drive
free space plus this torrent's allocated bytes, minus 100 GB. A custom limit
uses decimal GB and counts both partial downloads and retained uploaded files.
It persists across restarts and remains bounded by actual drive space. The RAM
buffer ceiling and RAM percentage do not apply to storage. The sliding window reserves
unfinished file bytes, shared torrent pieces and filesystem overhead before
admitting more files, and rechecks available space as it runs and after restart.
The transfer card shows the limit and actual disk usage; its storage tooltip
shows available drive space. Reducing a 200 GB allocation to a 100 GB limit
first reclaims confirmed copies and immediately queues complete files for upload.
The download window narrows to finish partial files so they can upload and free
space. Partial files are never deleted to meet the limit, so usage may temporarily
remain above it. Cloud outages and shared pieces may delay reclamation. Increasing
the limit allows waiting files to enter the window. Turn off **Keep Uploaded Files
for Sharing** in the same menu to restore immediate cleanup after confirmation.

More retained pieces may let this Mac upload useful data to more peers; disk
allocation itself does not grant download priority. Swarm availability and peer
reciprocation still govern throughput. Peer upload limits remain unchanged.

During a piece check, it shows **Checking downloaded pieces** and leaves the
download window intact until verification finishes. This also avoids repeatedly
restarting a long check when more upload confirmations arrive.
**Show in Finder** opens its staging folder.

**Pause** and **Stop** keep unfinished disk files for Resume. App or Mac restarts
also retain them. A missing or replaced storage disk must be reconnected before
the transfer can continue. A failed copy keeps the original RAM data. Removing
the torrent keeps remaining local files and completed PikPak files, but removes
the app's resume history. The chosen parent folder's other contents are never
used for automatic cleanup.

## Verified resume cache

The native engine saves its verified piece map and unfinished block state in
private `Engine/Resume` records, bound to both torrent identity and payload root.
Before reusing a record it checks its checksum, every payload path, file size,
device/inode identity, and nanosecond modification/change timestamps. The check
also covers libtorrent's boundary-block partfile. It reads file metadata instead
of rehashing every payload byte. Newly received pieces still pass the torrent's
hash before becoming complete.

Matching older checkpoints are also checked for impossible piece/block claims
beyond the current end of an ordinary payload file. Those claims are dropped so only the missing
pieces download again; intact verified files and their cloud receipts remain.
This recovery reads file attributes, not payload contents. A file is offered to
the upload worker only when its on-disk size exactly matches the torrent size.
An upload size error is retried automatically, but retrying alone cannot repair
an incomplete local file.

Clean Pause/Resume and app relaunches reuse matching checkpoints. Changed,
replaced, missing or moved data and corrupt checkpoints fall back to piece
checking. A crash after unsaved changes can also require a check. RAM-to-storage
migration checks the copied data once. Hash checks interrupted halfway through
resume checking their remaining pieces.

On first use, the engine can import verified pieces and partial blocks from the
old `.aria2` checkpoint only when its `MCVR0001` digest still matches every file.
It leaves that checkpoint intact. Without a valid trailer it checks the payload.
Queue selection, cloud upload receipts and configurable storage limits are
unchanged by the engine migration.

Released pieces are excluded from cached completion bits and are not advertised
to peers. Separate verified-file receipts keep an intact neighboring file ready
for cloud upload after a shared piece is withdrawn. Cleanup is fenced behind disk
writes and closed file handles and never releases a selected unfinished file.

## Downloads to this Mac

- Shows completed bytes, download/upload speed, peers and seeds.
- Pause, resume and stop preserve partial files. Remove Torrent removes the
  history entry and stops its work; downloaded files remain on disk.
- Reopening the app automatically resumes interrupted downloads and reuses
  verified progress for unchanged files. Explicit Pause and Stop remain held.
  Engine exits and missing external disks retry automatically with a capped
  delay; disk identity and cached-piece checks remain in place.
- Torrents use this Mac's network and disk, independently of PikPak login,
  User/Guest/Dynamic mode and transfer quotas. No PikPak credentials are sent
  to the torrent engine. Existing PikPak connection settings are unchanged.
- Three torrents may run concurrently. Total peer uploads are capped at
  4 MiB/s, with PikPak relays limited to 256 KiB/s each. Seeding stops after completion; BitTorrent still uploads pieces
  while a download is in progress.
- File lists need an available peer unless a `.torrent` file is supplied.
  Magnet metadata has no waiting timeout. Pure BitTorrent v2 magnets are not
  accepted by the app’s magnet input parser.
- Selecting files can require shared boundary pieces from adjacent files.
  Unselected files are removed at completion inside the torrent's own folder.
- Metadata is limited to 32 MiB and 200,000 listed files; queue storage is
  limited to 64 MiB. These are local memory/storage bounds.

## Engine and source

MyCloudDriver runs a native helper linked to
[libtorrent 2.0.14](https://github.com/arvidn/libtorrent/releases/tag/v2.0.14).
`scripts/libtorrent-relay-release.patch` adds a narrow operation that withdraws
verified pieces without restarting the torrent. The helper then fences disk I/O
before unlinking eligible files. It preserves the app's authenticated loopback
RPC contract, including verified file progress and per-connection handshake
status. A fresh secret is kept in the private runtime configuration. PikPak
credentials never enter the helper.

Queue, metadata and engine state live under
`~/Library/Application Support/MyCloudDriver/LocalTorrents` (directories 0700;
configuration and resume files 0600). No external RPC listener is enabled.
The helper uses the existing macOS network route; the upgrade does not bypass
VPN/proxy settings. System trust anchors verify HTTPS tracker certificates.

Run `python3 scripts/prepare-libtorrent-engine.py` before the release build.
It verifies pinned official libtorrent, Boost 1.88.0 and OpenSSL 3.6.4 archives,
builds static libraries and an arm64 macOS 13+ executable, and fingerprints its
sources, patch and build recipe. Build tooling is isolated under `.build`.
`--verify-only` checks the cached build offline. The installed app needs neither
Homebrew nor Python and links only system dylibs. `scripts/build-app.sh`
packages/signs the helper and includes its dependency licenses and source URLs.

The old aria2 helper remains bundled for regression tests and rollback. Its
GPL source, patch, static GMP source, licenses and reproduction instructions
remain alongside it. `scripts/prepare-torrent-engine.py` builds that helper.

`scripts/test-libtorrent-engine.py` runs generated loopback transfers with an
independent Python `libtorrent==2.0.14` client. It exercises µTP payload delivery,
TCP peer continuity during live shared-piece cleanup, selection changes,
unchanged-data resume, modified/corrupt-cache fallbacks, confined deletion, and
migration of aria2 verified pieces and partial blocks. It does not open the
user's queue or payload. Install the Python wheel in an isolated test environment;
it is a test dependency only.

The legacy `scripts/test-torrent-live-cleanup.py` and
`scripts/test-torrent-handshake.py` retain coverage of aria2's cleanup and
independent DH/RC4 handshake implementation.
