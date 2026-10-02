# Torrent connectivity investigation — 26 September 2026

The investigation found two app defects: negotiating sockets were displayed as
connected peers, and the portable engine could not negotiate standard encrypted
BitTorrent connections. Both fixes were rebuilt and installed. The target swarm
still had poor availability after those fixes; bypassing Shadowrocket did not
produce a successful handshake in the bounded comparison below.

Follow-up investigation restored the live download by discovering a working
seeder through peer exchange and introducing it to the app. The app then
sustained approximately 6–8 KB/s using its existing encryption and routing
settings. A short-lived peer cache was added so future resumes can retry known
working peers instead of losing them with the engine process. This resolves the
observed zero-speed stall. After installing that build, the app automatically
reconnected, found additional peers and reached approximately 0.23–0.59 MB/s
during the final minute of observation. Speeds remain dependent on the swarm.

## Confirmed defects and fixes

**Peer counts.** Upstream aria2 includes negotiating sockets in `getPeers` and
can retain an old peer ID when reconnecting. During the initial 65-second sample,
8–11 reported peers had no completed handshake and sent no data. The patched
engine now reports `handshakeCompleted` for the current connection. The app counts
only completed handshakes and shows outstanding attempts separately.

**Encrypted connections.** The previous portable build selected aria2's internal
Diffie–Hellman implementation. Its calculation did not interoperate with standard
peers. In a generated 2 MiB encrypted transfer against an independent stock aria2
seeder, the old engine transferred zero bytes in 40 seconds; stock aria2 completed
in four seconds. Building the portable engine with statically linked GMP 6.3.0
made the same transfer complete in four seconds with matching SHA-256. Apple TLS
and system-only dynamic dependencies are preserved. GMP source and license are
included with the app's engine.

**Network warning.** Virtual DNS addresses in `198.18.0.0/15` show interception by
a tunnel, but do not establish that torrent traffic is blocked. The old warning
incorrectly claimed traffic could not leave this Mac. It now describes the
observed facts and the remaining uncertainty. Router port mapping success also
does not establish externally reachable inbound connectivity.

## Network comparison

The user authorized temporary direct peer tests. Direct sockets were bound to
the physical `en0` interface with `IP_BOUND_IF`; comparison sockets used the
existing Shadowrocket tunnel and its current routing policy. Global routing and
Shadowrocket settings were unchanged. Peer probes requested no file payload.

| Sample | Through Shadowrocket | Direct through en0 |
| --- | --- | --- |
| Original 11 peer addresses, encrypted handshake | 0 complete handshakes | 0 complete handshakes |
| Fresh 12 peer addresses, plaintext handshake | 0 complete handshakes | 0 complete handshakes |
| Same fresh 12 addresses, MSE negotiation | 0 complete handshakes | 0 complete handshakes |
| Domestic HTTPS control, certificate verified | Success, tunnel source address | Success, physical interface source address |

The first comparison used four-second socket timeouts; the fresh comparison
used eight seconds per blocking operation. Two fresh peers accepted direct TCP
connections in approximately 240–350 ms but then closed or stopped responding
during negotiation. The other ten did not complete direct TCP connections.
Shadowrocket accepted sockets locally almost immediately; this was not evidence
of a completed connection to the remote peer. Its rules may choose different
routes for different destinations, so these results describe the tested policy,
not every possible proxy server.

The rebuilt engine also downloaded 1 MiB from the
[official Ubuntu control torrent](https://releases.ubuntu.com/24.04/)
through the existing Shadowrocket route within 30 seconds, reaching a sampled
54,841 B/s. This establishes that the current route can carry BitTorrent payload;
it is not a speed benchmark. An isolated stock aria2 test of the target torrent
remained at zero bytes for 55 seconds, so its poor availability was not confined
to the old bundled engine.

UDP tracker responses and DHT responses were received through the current
network. One tracker reported four seeds and ten leechers for the target torrent.
Tracker counts are advertisements, not proof that those peers are reachable or
willing to send, and counts from different trackers must not be added together.

## Live transfer and settings

In the first 80-second observation after reinstall, the target torrent briefly
connected to a seeder advertising needed pieces, but the seeder kept the local
client choked (did not grant an upload slot). Another completed connection
advertised no pieces needed by the current selection. Neither sent payload during
that observation. This differs from the previous false count of connected peers:
the rebuilt engine can complete real handshakes, but a completed handshake alone
does not guarantee data.

A final 60-second sample remained at 0 B/s with no completed peer connections
and no increase in verified pieces. The transfer was active and continued
attempting connections. The app fixes are verified; the target torrent's stall
was not resolved during this observation.

There was no configured download-rate cap, no active piece verification, and no
wait for relay upload space. The disk buffer used approximately 64.4 GB, with
approximately 399 GB available on the volume. Peer discovery, peer exchange, and
IPv4/IPv6 DHT were enabled. The macOS firewall allowed the installed torrent
engine. External inbound reachability was not independently verified.

The reinstall preserved all 14,623 selected file records, all 4,657 confirmed
upload records, and 88,112,716,936 confirmed cloud bytes. Temporary debug logging
was restored to its previous settings. The active download remained running.

## Validation

- GMP's 177 build tests passed.
- Native torrent tests passed, including authoritative handshake flags,
  reconnect handling, corrected warnings, storage limits, and lifecycle cases.
- `scripts/test-torrent-handshake.py` passed an independent Python DH/RC4 peer,
  SHA-256 payload verification, and pending/completed peer-count checks. The same
  fixture failed with the old installed engine during encrypted key agreement.
- `scripts/test-torrent-live-cleanup.py` passed live storage reclamation, sharing,
  cached verification, invalid-cache fallback, and payload integrity checks.
- The app build, engine dependency verification, code signatures, installation
  comparison, and `git diff --check` passed.

These tests do not prove that every advertised peer is offline or that another
network could never improve the result. They establish the app defects, verify
their fixes, and show that direct bypass did not improve the tested handshakes.
Remaining download progress depends on reaching peers that have the needed
pieces and are willing to serve them.

## Follow-up after “continue”

An isolated libtorrent 2.0.14 comparison enabled both TCP and µTP, using temporary
sparse storage and a 512 KiB/s rate limit. Direct sockets used `en0`; tunnel
sockets used `utun7`. The direct test also resolved the already-configured UDP
trackers through the LAN resolver, since virtual tunnel DNS addresses cannot be
used by sockets bound outside the tunnel. It included IPv6 tracker endpoints.
System routing and proxy settings were unchanged.

The initial single-file tests received no payload. A broader comparison requested
only pieces absent from the live download and still needed by its selected files.
The direct test again received no payload over 180 seconds. Through the tunnel,
libtorrent found a complete seeder through peer exchange and received about
645 KB at sampled rates of 5–8 KB/s. Its two sustained data connections used TCP;
µTP also reached peers during discovery. These results do not establish that
µTP or forced encryption is required to download from the discovered seeder.

Neither working endpoint appeared in the app's previously observed peer list.
A temporary loopback peer-exchange connection introduced the same endpoints to
the running app. Without restarting it or changing encryption settings, the app
completed a handshake with the complete seeder and immediately received payload.
An 80-second sample showed sustained nonzero download speed, approximately
6–8 KB/s. Its choke flag remained set while some data arrived; a choke flag alone
therefore cannot establish that a peer sends nothing, particularly with allowed
fast requests.

The persistent improvement is a bounded peer cache for confirmed public
torrents, plus authenticated `aria2.addPeers` support. Only peers that completed
a handshake can enter the cache. Transferring peers and seeds are preferred;
unknown incoming ports, local/virtual addresses, stale or malformed entries are
excluded. At most 64 endpoints per torrent and 128 torrent caches are retained,
with a 24-hour lifetime. Private torrents and metadata whose privacy is not yet
known do not use the cache. Restoring hints uses the existing connection scheduler
and routing, and never counts a cached address as an established connection.

The independent encrypted-peer regression now returns no peers from its tracker.
It must restore a peer via the new RPC, complete its handshake and verify a 2 MiB
payload checksum. Invalid batches are rejected before any peer is added, and
duplicate endpoints are ignored.

The new build was rebuilt, signed, installed and relaunched. The previously
working seeder reconnected automatically, and the app refreshed its peer cache
after launch. Over the final 60-second sample, two peers sent data, the sampled
peak was 591,562 B/s, and completed/block progress increased by 24,723,456 bytes.
The last sample reported three completed peer connections, two sending, and
289,242 B/s. A subsequent reading fell to 7,956 B/s with one connected, sending
peer, so the faster rate was temporary and peer availability remains variable.
No piece check was active in that observation. Selection, the full
file manifest, all 4,657 upload receipts, confirmed cloud bytes and the chosen
storage location were preserved exactly or monotonically as appropriate.

A final independent direct test explicitly targeted that newly discovered
complete seeder, rather than relying on trackers to find it. It received no
payload in 45 seconds, while the app continued receiving through Shadowrocket.
No global routing, proxy or encryption settings were changed. All temporary
comparison clients stopped and their payload directories were removed.

Validation for this build passed: the full native torrent suite, the independent
encrypted cached-peer fixture, live cleanup and verified-resume regressions,
engine dependency verification, app build, installed-file comparison, code
signatures and whitespace checks.

## Slow-speed follow-up

The next 150-second live sample had only one sending peer. Sampled rates peaked
at 9,030 B/s and completed/block progress increased by 1,032,192 bytes. Requests
were continuously outstanding and replenished when blocks arrived. Download
limits remained zero, no verification was active, and the relay was not waiting
for storage. The cached seeder responsible for the earlier faster burst was
reintroduced once; both its encrypted and legacy TCP attempts ended before a
BitTorrent handshake completed. This does not identify whether the remote peer
or an intermediary closed those connections.

An independent libtorrent test of the same missing selected pieces ran for
180 seconds through the existing tunnel, with TCP and µTP enabled and a
512 KiB/s ceiling. It reached four completed peer connections, received at least
16,303,136 payload bytes by the final sample, and peaked at 139,730 B/s. Almost
all payload came from a newly reachable seeder over µTP. The live app continued
to receive approximately 8 KB/s from its existing TCP peer. The independent
payload lived in temporary storage and was removed; it is not progress imported
into the live download or proof of complete-piece checksum verification.

After that client stopped, a separate 90-second TCP-only test targeted the newly
reachable seeder and the previously faster cached seeder. Neither completed a
handshake, and no payload arrived. Trackers, DHT and peer exchange were disabled
for this comparison so it could not substitute other endpoints. Both tests used
the existing tunnel, without changing system routing or proxy settings.

A following 90-second µTP-only retry of those same two endpoints also received
no payload and no completed BitTorrent handshake. UDP transport packets were
exchanged before the connections ended. Consequently, the earlier faster µTP
session proves a reachable transport opportunity at that time, not a repeatable
speed improvement. The sequential TCP/µTP comparison is confounded by changing
peer or route availability; it cannot establish that switching transports alone
will restore a connection. All three independent sessions were stopped and their
temporary payloads removed.

An 85-second cold-start Ubuntu control on the bundled engine received about
3.67 MB and reached a sampled 58,566 B/s with only one identified peer. This
confirms continued TCP payload transfer but is not a measurement of the internet
connection's capacity or evidence that the current proxy route is optimal.

The installed aria2 engine supports TCP peer traffic but has no µTP transport;
UDP tracker and DHT support do not add µTP. Upstream still tracks this as an
[unimplemented feature](https://github.com/aria2/aria2/issues/1386). The peer's
transport was identified using libtorrent's socket flag and session counters,
consistent with its
[versioned peer-info definition](https://github.com/arvidn/libtorrent/blob/v2.0.14/include/libtorrent/peer_info.hpp).
This exposes a useful engine capability gap. Supporting TCP and µTP would allow
more connection choices, but these measurements do not establish a guaranteed
sustained rate or show that storage capacity is the current bottleneck.


## TCP/µTP engine upgrade (2.3.0)

The default backend is now a native libtorrent 2.0.14 helper. It keeps the
existing authenticated loopback RPC boundary and runs on macOS 13+ without
Homebrew or Python. Static OpenSSL 3.6.4 and Boost 1.88.0 are pinned to verified
official archives. The old aria2 helper and original checkpoints remain available
for rollback. No system proxy or network route was changed for the upgrade.

The helper imports aria2 verified pieces and unfinished blocks only after the
old verification trailer matches the current metadata and every payload file.
The live torrent's 14,623 paths matched exactly between engines in a read-only
preflight. New private resume records bind file identity/timestamps, boundary
partfiles, verified file receipts and the libtorrent piece map to the payload
root. Changed or corrupt state falls back to normal checking.

Live cleanup withdraws complete pieces, retires boundary partfile slots behind
a disk fence, then closes and unlinks eligible files. Intact verified neighbors
remain upload-ready. Later admission of a reclaimed boundary file enables its
pieces again. File priority changes need no engine pause. Incoming peers whose
listening port is unknown are excluded from the reconnect cache.

A generated last-piece announcement test exposed an upstream connection edge:
`incoming_have` could classify a peer as a seed and disconnect it as uninteresting
before registering interest in its newly announced piece. The versioned patch
moves that decision to the existing interest-aware check later in the function.

Validation completed before installation:

- Native model regression suite, including live storage limits, retained copies,
  cloud receipts, pause/restart and network recovery.
- The packaged native helper transferred 2 MiB over µTP from an independent
  libtorrent peer, with matching SHA-256; full-seed reclamation removed all
  advertised pieces afterward.
- TCP shared-piece cleanup retained the supplying connection, rejected unsafe
  deletion, preserved complete neighboring files and continued transfer after
  live file selection changes.
- Cached restart, same-size edits with restored mtime, corrupt records, symlink
  confinement, aria2 complete-piece/partial-block import and later boundary-file
  admission all passed.
- The Swift app flow fetched magnet metadata without payload, downloaded a file
  subset, paused/restarted, verified SHA-256 and left unselected files absent.
- A 300 MiB generated relay moved from RAM to storage, restarted, sent verified
  files to a synthetic cloud sink and reclaimed data only after confirmation.
- Release build, arm64/macOS 13 deployment target, system-only dylib dependency
  check and strict code-signature verification passed.

The pre-install live sample (12 readings over roughly 55 seconds) averaged
7,726 B/s and peaked at 8,641 B/s, with three handshaked peers and one sender at
the last reading. This is a before/after observation, not a controlled transport
benchmark: remote peer availability can change while the app restarts.

The upgrade was installed as version 2.3.0, build 224. The old app and saved
queue are backed up in `update-backup-20260926-044800`. The cleanly saved
aria2 checkpoint contained its verified-resume trailer; the new live session
reported `resumeSource=aria2-verified` without a full check. All 14,623 selected
files and all 4,659 pre-upgrade cloud receipts were retained. The live uploader
then confirmed another file. A native resume record was written with mode 0600.

The first post-install reading was 222,636 B/s, with one TCP and two µTP peers,
all sending payload. A subsequent two-minute sample is recorded separately.

The follow-up sample lasted 122.3 seconds. The reported speed
averaged 17,364 B/s (median 7,811; sampled peak
162,585), but the payload counter advanced only 1,039,559
bytes, about 8,500 B/s over that
window. Reported rates smooth earlier traffic and overstate this window's payload
average after the initial burst. The final reading was 5,882 B/s with
one TCP and one µTP connection. The faster µTP seed had disconnected; the remaining
µTP peer was mostly receiving uploads. No piece-check state appeared in the
sample. The additional transport works, but this swarm has not sustained its
initial speed increase. This is not evidence of a stable throughput improvement.

The final helper adjustment uses libtorrent's `num_connections` for total open
attempts, while the existing handshake census continues to count only connected
peers. `num_peers` excludes half-open attempts and hid that diagnostic detail.
The updated package is build 225.

Build 225 was installed and a real restart reused `resumeSource=libtorrent` with
no piece check. The selected-file count remained 14,623; all
4,660 cloud receipts remained present. The final spot check showed
2 handshaked µTP peers sending a combined 218,184 B/s.
Together with the earlier slow readings, this confirms variable bursts rather
than a guaranteed sustained rate. The torrent remains active on the existing
network route. The final rollback backup is
`update-backup-20260926-045214`
and includes the native resume records as well as the app and queue.


## Upload size error after the engine upgrade

Build 228 fixes torrent padding being treated as ordinary upload files. A live
upload batch contained 58 short padding stubs alongside 57 ready payload files;
the exact-size safety check correctly rejected the first stub, and the whole
batch repeated on the five-minute retry schedule. Engine padding flags identify
these virtual entries without inspecting downloaded content. The upload queue,
selection UI and payload totals now exclude both explicit and legacy BitComet
padding. Full metadata remains in the piece layout, and existing cloud receipts
are retained. Removing a legacy padding stub does not withdraw real pieces.
Virtual padding no longer adds a separate boundary reservation for every file.
Legacy padding stubs are removed through live engine cleanup so their deletion
is checkpointed instead of invalidating the next resume manifest.

Ordinary files also require an exact physical size before being reported ready.
A matching older cache with ordinary piece/block claims beyond EOF drops only
those impossible claims and preserves usable verified data. Generated fixtures
cover recovery and restart, padding classification and cleanup, shared-piece
cleanup, old-engine migration, and independent TCP/µTP transfers. The Swift
transfer suite and release build pass. During the live check, 57 additional
cloud receipts were confirmed after the size gate was corrected.

The investigation read application state, torrent metadata flags and filesystem
attributes only. No downloaded payload was opened, previewed or hashed by the
diagnostic tools. All content-based validation used generated fixture data.

The final installed build is 2.3.0 (228). After the already-running check
finished, its next launch reported `resumeSource=libtorrent` with no piece check.
All 4,718 cloud receipts were preserved, 7,309 virtual padding entries were
excluded from selection, and all 5,156 remaining payload files were admitted to
the live download window. Rollback app, queue and engine state are saved in
`dist/update-backup-20260926-052943`.
